package vultr

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

var (
	errRemoteSSHConnection     = errors.New("SSH connection failed")
	errRemoteSSHAuthentication = errors.New("SSH authentication failed")
	errRemoteSSHExecution      = errors.New("SSH deployment rerun failed")
)

const (
	vultrCloudInitUserDataPath = "/var/lib/cloud/instance/user-data.txt"
	managedSSHRepairCommand    = "test -f " + vultrCloudInitUserDataPath + " && exec flock -w 5 /run/lock/privatedeploy-repair.lock timeout --signal=TERM --kill-after=10s 120s /bin/bash -- " + vultrCloudInitUserDataPath
	managedSSHConnectTimeout   = 10 * time.Second
	managedSSHRepairTimeout    = 135 * time.Second
)

// runRemoteDeploymentRepair reruns only the original cloud-init payload on
// the same VPS. The command is constant: no password, private key, user-data,
// or caller-controlled value is interpolated into the remote shell. stdout and
// stderr are intentionally discarded so deployment secrets can never reach
// application logs through shell tracing or package-manager output.
func runRemoteDeploymentRepair(ctx context.Context, ip, privatePEM string) error {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return errRemoteSSHConnection
	}
	return runRemoteDeploymentRepairAtAddress(ctx, net.JoinHostPort(ip, "22"), privatePEM)
}

func runRemoteDeploymentRepairAtAddress(ctx context.Context, address, privatePEM string) error {
	signer, err := ssh.ParsePrivateKey([]byte(privatePEM))
	if err != nil {
		return errors.New("managed SSH recovery key is invalid")
	}
	return runRemoteDeploymentRepairWithAuth(ctx, address, ssh.PublicKeys(signer))
}

func runRemoteDeploymentRepairWithAuth(ctx context.Context, address string, auth ssh.AuthMethod) error {
	// The remote timeout bounds script execution, while this local deadline
	// also covers a stalled SSH transport that never delivers the exit status.
	if ctx == nil {
		ctx = context.Background()
	}
	parentCtx := ctx
	sshCtx, cancel := context.WithTimeout(ctx, managedSSHRepairTimeout)
	defer cancel()
	ctx = sshCtx
	contextOrStaticError := func(static error) error {
		if parentCtx.Err() != nil {
			return parentCtx.Err()
		}
		// The derived deadline can become observable a few instructions before
		// the parent timer reports its own error. Preserve cancellation semantics
		// instead of racing them into a misleading authentication failure.
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return static
	}

	config := &ssh.ClientConfig{
		User: "root",
		Auth: []ssh.AuthMethod{auth},
		// Vultr does not expose a provisioned instance host key through its API.
		// The connection is restricted to the IP returned for this exact VPS and
		// sends only a public-key signature and this package's constant repair
		// command; there is no provider-authenticated host-key value to pin on the
		// first repair connection.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         managedSSHConnectTimeout,
	}

	dialer := net.Dialer{Timeout: managedSSHConnectTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return contextOrStaticError(errRemoteSSHConnection)
	}
	defer conn.Close()

	handshakeDeadline := time.Now().Add(managedSSHConnectTimeout)
	if deadline, ok := ctx.Deadline(); ok && deadline.Before(handshakeDeadline) {
		handshakeDeadline = deadline
	}
	_ = conn.SetDeadline(handshakeDeadline)
	handshakeDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-handshakeDone:
		}
	}()
	sshConn, channels, requests, err := ssh.NewClientConn(conn, address, config)
	close(handshakeDone)
	if err != nil {
		return contextOrStaticError(errRemoteSSHAuthentication)
	}
	_ = conn.SetDeadline(time.Time{})
	client := ssh.NewClient(sshConn, channels, requests)
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return errRemoteSSHExecution
	}
	defer session.Close()
	if err := session.Start(managedSSHRepairCommand); err != nil {
		return errRemoteSSHExecution
	}

	wait := make(chan error, 1)
	go func() { wait <- session.Wait() }()
	select {
	case <-ctx.Done():
		_ = session.Close()
		_ = client.Close()
		<-wait
		return contextOrStaticError(errRemoteSSHExecution)
	case err := <-wait:
		if err == nil {
			return nil
		}
		return errRemoteSSHExecution
	}
}
