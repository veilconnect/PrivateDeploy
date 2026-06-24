package digitalocean

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
)

// cloudInitUserDataPath is where cloud-init persists the rendered user-data on
// the Debian droplets we provision.
const cloudInitUserDataPath = "/var/lib/cloud/instance/user-data.txt"

// recoverNodeRecordForInstance rebuilds an incomplete record by SSHing into the
// droplet (with the managed key) and parsing its cloud-init user-data, since
// DigitalOcean's API can't return user-data. Returns the original record
// unchanged on any failure (best-effort; never fatal to a list).
func (p *Provider) recoverNodeRecordForInstance(ctx context.Context, ip string, record cloud.InstanceRecord) (cloud.InstanceRecord, bool) {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return record, false
	}
	_, privPEM, err := p.ensureManagedSSHKey(ctx)
	if err != nil || strings.TrimSpace(privPEM) == "" {
		return record, false
	}
	script, err := readRemoteUserData(ctx, ip, privPEM)
	if err != nil || strings.TrimSpace(script) == "" {
		return record, false
	}
	recovered := record
	if !cloud.RecoverInstanceRecordFromUserData(script, &recovered) {
		return record, false
	}
	return recovered, true
}

func readRemoteUserData(ctx context.Context, ip, privPEM string) (string, error) {
	signer, err := ssh.ParsePrivateKey([]byte(privPEM))
	if err != nil {
		return "", err
	}
	cfg := &ssh.ClientConfig{
		User: "root",
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		// The droplet is freshly created and the API does not expose its host
		// key, so there is no trusted key to pin against — TOFU and ignore are
		// equivalent on this first connect. Trade-off: a MITM on the droplet's
		// IP could serve forged user-data. Acceptable for a best-effort,
		// owner-initiated recovery read; we never send secrets to the host.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}

	addr := net.JoinHostPort(ip, "22")
	dialer := net.Dialer{Timeout: 10 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return "", err
	}
	defer conn.Close()

	sshConn, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		return "", err
	}
	client := ssh.NewClient(sshConn, chans, reqs)
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	out, err := session.Output("cat " + cloudInitUserDataPath)
	if err != nil {
		return "", fmt.Errorf("read remote user-data: %w", err)
	}
	return string(out), nil
}
