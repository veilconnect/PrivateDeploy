package ssh

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSHSession manages an SSH connection to a remote server.
type SSHSession struct {
	client *ssh.Client
	host   string
	port   int
}

// NewSession establishes a new SSH connection.
func NewSession(host string, port int, user string, auth ssh.AuthMethod) (*SSHSession, error) {
	return NewSessionContext(context.Background(), host, port, user, auth)
}

// NewSessionContext establishes SSH with cancellation propagated through the
// TCP dial and SSH handshake. The fixed dial timeout remains a ceiling when
// the caller's deadline is longer.
func NewSessionContext(ctx context.Context, host string, port int, user string, auth ssh.AuthMethod) (*SSHSession, error) {
	config := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{auth},
		HostKeyCallback: trustOnFirstUseHostKeyCallback(""),
		Timeout:         15 * time.Second,
	}

	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	netConn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("SSH connect to %s failed: %w", addr, err)
	}
	handshakeDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = netConn.Close()
		case <-handshakeDone:
		}
	}()
	conn, chans, reqs, err := ssh.NewClientConn(netConn, addr, config)
	close(handshakeDone)
	if err != nil {
		_ = netConn.Close()
		return nil, fmt.Errorf("SSH handshake with %s failed: %w", addr, err)
	}
	client := ssh.NewClient(conn, chans, reqs)

	return &SSHSession{
		client: client,
		host:   host,
		port:   port,
	}, nil
}

// TestConnection runs a simple command to verify the connection is alive.
func (s *SSHSession) TestConnection() error {
	_, err := s.RunCommand("echo ok")
	return err
}

// RunCommand executes a single command and returns its combined output.
func (s *SSHSession) RunCommand(cmd string) (string, error) {
	return s.RunCommandContext(context.Background(), cmd)
}

func (s *SSHSession) RunCommandContext(ctx context.Context, cmd string) (string, error) {
	session, err := s.client.NewSession()
	if err != nil {
		return "", fmt.Errorf("failed to create session: %w", err)
	}
	defer session.Close()

	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr

	done := make(chan error, 1)
	go func() { done <- session.Run(cmd) }()
	var runErr error
	select {
	case runErr = <-done:
	case <-ctx.Done():
		_ = session.Close()
		<-done
		return "", ctx.Err()
	}
	if runErr != nil {
		combined := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
		return combined, fmt.Errorf("command failed: %w\noutput: %s", runErr, combined)
	}

	return strings.TrimSpace(stdout.String()), nil
}

// RunScript pipes a script into bash -s and streams output to the provided writer.
// If out is nil, output is discarded.
func (s *SSHSession) RunScript(script string, out io.Writer) error {
	return s.RunScriptContext(context.Background(), script, out)
}

func (s *SSHSession) RunScriptContext(ctx context.Context, script string, out io.Writer) error {
	session, err := s.client.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create session: %w", err)
	}
	defer session.Close()

	session.Stdin = strings.NewReader(script)
	if out != nil {
		session.Stdout = out
		session.Stderr = out
	}

	done := make(chan error, 1)
	go func() { done <- session.Run("bash -s") }()
	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("script execution failed: %w", err)
		}
	case <-ctx.Done():
		_ = session.Close()
		<-done
		return ctx.Err()
	}

	return nil
}

// ServerInfo holds detected information about the remote server.
type ServerInfo struct {
	OS     string `json:"os"`
	Arch   string `json:"arch"`
	Memory int    `json:"memoryMB"`
}

// DetectServer gathers basic information about the remote server.
func (s *SSHSession) DetectServer() (*ServerInfo, error) {
	return s.DetectServerContext(context.Background())
}

func (s *SSHSession) DetectServerContext(ctx context.Context) (*ServerInfo, error) {
	osInfo, _ := s.RunCommandContext(ctx, "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
	if osInfo == "" {
		osInfo, _ = s.RunCommandContext(ctx, "uname -s")
	}
	arch, _ := s.RunCommandContext(ctx, "uname -m")
	memStr, _ := s.RunCommandContext(ctx, "grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}'")
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	memMB := 0
	fmt.Sscanf(memStr, "%d", &memMB)

	return &ServerInfo{
		OS:     osInfo,
		Arch:   arch,
		Memory: memMB,
	}, nil
}

// CheckPorts checks which of the given ports are currently listening.
func (s *SSHSession) CheckPorts(ports []int) (map[int]bool, error) {
	return s.checkPortsContext(context.Background(), ports, "tcp")
}

func (s *SSHSession) CheckTCPPortsContext(ctx context.Context, ports []int) (map[int]bool, error) {
	return s.checkPortsContext(ctx, ports, "tcp")
}

func (s *SSHSession) CheckUDPPortsContext(ctx context.Context, ports []int) (map[int]bool, error) {
	return s.checkPortsContext(ctx, ports, "udp")
}

func (s *SSHSession) checkPortsContext(ctx context.Context, ports []int, network string) (map[int]bool, error) {
	result := make(map[int]bool, len(ports))
	for _, p := range ports {
		result[p] = false
	}

	command := "ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null"
	if network == "udp" {
		command = "ss -H -lun 2>/dev/null || netstat -lun 2>/dev/null"
	}
	output, err := s.RunCommandContext(ctx, command)
	if err != nil {
		return result, err
	}

	for _, p := range ports {
		portStr := fmt.Sprintf(":%d ", p)
		if strings.Contains(output, portStr) {
			result[p] = true
		}
	}

	return result, nil
}

// Close terminates the SSH connection.
func (s *SSHSession) Close() error {
	if s.client != nil {
		return s.client.Close()
	}
	return nil
}

// PasswordAuth returns an ssh.AuthMethod for password authentication.
func PasswordAuth(password string) ssh.AuthMethod {
	return ssh.Password(password)
}

// PrivateKeyAuth returns an ssh.AuthMethod for public key authentication.
func PrivateKeyAuth(pemBytes []byte) (ssh.AuthMethod, error) {
	signer, err := ssh.ParsePrivateKey(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}
	return ssh.PublicKeys(signer), nil
}
