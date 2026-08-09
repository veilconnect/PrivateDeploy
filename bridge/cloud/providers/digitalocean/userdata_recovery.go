package digitalocean

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
)

// cloudInitUserDataPath is where cloud-init persists the rendered user-data on
// the Debian droplets we provision.
const cloudInitUserDataPath = "/var/lib/cloud/instance/user-data.txt"

const (
	managedSSHConnectTimeout       = 10 * time.Second
	managedUserDataRepairTimeout   = 3 * time.Minute
	managedUserDataRepairKillGrace = 15 * time.Second
	managedUserDataOutputLimit     = 32 * 1024
)

// remoteManagedUserDataRepairCommand contains no client-provided values or
// credentials. The script already lives on the droplet. A non-blocking flock
// prevents two repair clicks/processes from running it concurrently, while the
// remote timeout bounds package-manager/cloud-init failures even if the desktop
// process loses its connection.
const remoteManagedUserDataRepairCommand = `set -euo pipefail
umask 077
script='/var/lib/cloud/instance/user-data.txt'
lock='/run/lock/privatedeploy-userdata-repair.lock'
[ -f "$script" ] && [ ! -L "$script" ]
exec 9>"$lock"
flock --exclusive --nonblock --conflict-exit-code 75 9
timeout --signal=TERM --kill-after=15s 180s /bin/bash "$script" 2>&1 | tail -c 32768`

// boundedSSHOutput consumes remote stdout/stderr without retaining secrets or
// allowing an unexpectedly noisy script to grow client memory. It deliberately
// stores no bytes; counters are useful only for diagnostics/tests and are never
// included in user-visible errors.
type boundedSSHOutput struct {
	mu        sync.Mutex
	limit     int
	accepted  int
	truncated bool
}

func newBoundedSSHOutput(limit int) *boundedSSHOutput {
	return &boundedSSHOutput{limit: limit}
}

func (output *boundedSSHOutput) Write(payload []byte) (int, error) {
	output.mu.Lock()
	defer output.mu.Unlock()
	remaining := output.limit - output.accepted
	if remaining > 0 {
		accepted := len(payload)
		if accepted > remaining {
			accepted = remaining
		}
		output.accepted += accepted
	}
	if len(payload) > remaining {
		output.truncated = true
	}
	// Report the complete write as consumed: bytes beyond the cap are discarded
	// rather than back-pressuring a remote process that must reach its timeout.
	return len(payload), nil
}

func (output *boundedSSHOutput) stats() (accepted int, truncated bool) {
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.accepted, output.truncated
}

// recoverNodeRecordForInstance rebuilds an incomplete record by SSHing into the
// droplet (with the managed key) and parsing its cloud-init user-data, since
// DigitalOcean's API can't return user-data. Returns the original record
// unchanged on any failure (best-effort; never fatal to a list).
func (p *Provider) recoverNodeRecordForInstance(ctx context.Context, ip string, record nodeRecord) (nodeRecord, bool) {
	ip = strings.TrimSpace(ip)
	wantFingerprint := strings.TrimSpace(record.ManagedSSHKeyFingerprint)
	if ip == "" || wantFingerprint == "" {
		return record, false
	}
	// Listing an old/incomplete droplet must never provision a new account key:
	// a newly registered key is not attached retroactively. Only use the exact
	// locally persisted key fingerprint recorded when this droplet was created.
	privPEM, err := cloud.LoadSecret(p.configPath, managedSSHKeyScope)
	if err != nil || strings.TrimSpace(privPEM) == "" {
		return record, false
	}
	_, fingerprint, err := publicKeyAndFingerprintFromPEM(privPEM)
	if err != nil || fingerprint != wantFingerprint {
		return record, false
	}
	script, err := readRemoteUserData(ctx, ip, privPEM)
	if err != nil || strings.TrimSpace(script) == "" {
		return record, false
	}
	recovered := record
	if !cloud.RecoverInstanceRecordFromUserData(script, &recovered.InstanceRecord) {
		return record, false
	}
	return recovered, true
}

func readRemoteUserData(ctx context.Context, ip, privPEM string) (string, error) {
	address := net.JoinHostPort(ip, "22")
	client, cleanup, err := dialManagedSSH(ctx, address, privPEM)
	if err != nil {
		return "", err
	}
	defer cleanup()

	session, err := client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	out, err := session.Output("cat " + cloudInitUserDataPath)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return "", ctxErr
		}
		return "", fmt.Errorf("read remote user-data: %w", err)
	}
	return string(out), nil
}

func dialManagedSSH(ctx context.Context, address, privPEM string) (*ssh.Client, func(), error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	signer, err := ssh.ParsePrivateKey([]byte(privPEM))
	if err != nil {
		return nil, nil, errors.New("managed SSH private key is invalid")
	}
	cfg := &ssh.ClientConfig{
		User: "root",
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		// DigitalOcean's API does not expose the droplet host key, so there is no
		// provider-authenticated fingerprint to pin here. The client sends only a
		// constant command and public-key signature; it never transmits the node
		// credentials embedded in the already-remote user-data script.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         managedSSHConnectTimeout,
	}

	dialer := net.Dialer{Timeout: managedSSHConnectTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, nil, ctxErr
		}
		return nil, nil, errors.New("managed SSH connection failed")
	}

	watchDone := make(chan struct{})
	var cleanupOnce sync.Once
	cleanupConn := func() {
		cleanupOnce.Do(func() {
			close(watchDone)
			_ = conn.Close()
		})
	}
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-watchDone:
		}
	}()

	handshakeDeadline := time.Now().Add(managedSSHConnectTimeout)
	if deadline, ok := ctx.Deadline(); ok && deadline.Before(handshakeDeadline) {
		handshakeDeadline = deadline
	}
	_ = conn.SetDeadline(handshakeDeadline)

	sshConn, chans, reqs, err := ssh.NewClientConn(conn, address, cfg)
	if err != nil {
		cleanupConn()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, nil, ctxErr
		}
		return nil, nil, errors.New("managed SSH handshake failed")
	}
	_ = conn.SetDeadline(time.Time{})
	client := ssh.NewClient(sshConn, chans, reqs)
	cleanup := func() {
		cleanupOnce.Do(func() {
			close(watchDone)
			_ = client.Close()
		})
	}
	return client, cleanup, nil
}

func (p *Provider) rerunManagedUserData(ctx context.Context, instanceID, ip string) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	if strings.TrimSpace(ip) == "" {
		return errors.New("existing droplet has no public IPv4 address")
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return errors.New("managed SSH repair metadata is unavailable")
	}
	record, ok := records[strings.TrimSpace(instanceID)]
	wantFingerprint := strings.TrimSpace(record.ManagedSSHKeyFingerprint)
	if !ok || wantFingerprint == "" {
		return errors.New("existing droplet predates the PrivateDeploy managed SSH recovery key")
	}
	privPEM, err := cloud.LoadSecret(p.configPath, managedSSHKeyScope)
	if err != nil || strings.TrimSpace(privPEM) == "" {
		// Do not call ensureManagedSSHKey here: a newly registered account key
		// cannot be retroactively attached to this existing droplet. Creating one
		// would falsely imply that automatic repair can authenticate.
		return errors.New("existing droplet has no usable PrivateDeploy managed SSH key")
	}
	_, fingerprint, err := publicKeyAndFingerprintFromPEM(privPEM)
	if err != nil {
		return errors.New("PrivateDeploy managed SSH recovery key is invalid")
	}
	if fingerprint != wantFingerprint {
		return errors.New("PrivateDeploy managed SSH recovery key no longer matches this droplet")
	}
	return rerunRemoteUserData(ctx, net.JoinHostPort(ip, "22"), privPEM)
}

func rerunRemoteUserData(ctx context.Context, address, privPEM string) error {
	if ctx == nil {
		ctx = context.Background()
	}
	runCtx, cancel := context.WithTimeout(
		ctx,
		managedSSHConnectTimeout+managedUserDataRepairTimeout+managedUserDataRepairKillGrace+5*time.Second,
	)
	defer cancel()

	client, cleanup, err := dialManagedSSH(runCtx, address, privPEM)
	if err != nil {
		return err
	}
	defer cleanup()

	session, err := client.NewSession()
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		if runCtx.Err() != nil {
			return errors.New("managed deployment script exceeded its local time limit")
		}
		return errors.New("managed SSH session could not be opened")
	}
	defer session.Close()
	output := newBoundedSSHOutput(managedUserDataOutputLimit)
	session.Stdout = output
	session.Stderr = output

	done := make(chan error, 1)
	go func() {
		done <- session.Run(remoteManagedUserDataRepairCommand)
	}()

	select {
	case runErr := <-done:
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		if runErr == nil {
			return nil
		}
		var exitErr *ssh.ExitError
		if errors.As(runErr, &exitErr) {
			switch exitErr.ExitStatus() {
			case 75:
				return errors.New("an in-place deployment repair is already running on this droplet")
			case 124, 137, 143:
				return errors.New("managed deployment script exceeded its remote time limit")
			default:
				return fmt.Errorf("managed deployment script exited with status %d", exitErr.ExitStatus())
			}
		}
		// Never interpolate runErr or captured output: remote shell diagnostics can
		// contain the credentials embedded in cloud-init user-data.
		return errors.New("managed deployment script did not complete successfully")
	case <-runCtx.Done():
		_ = client.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		return errors.New("managed deployment script exceeded its local time limit")
	}
}
