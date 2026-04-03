package ssh

import (
	"bytes"
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
	config := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{auth},
		HostKeyCallback: trustOnFirstUseHostKeyCallback(""),
		Timeout:         15 * time.Second,
	}

	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return nil, fmt.Errorf("SSH connect to %s failed: %w", addr, err)
	}

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
	session, err := s.client.NewSession()
	if err != nil {
		return "", fmt.Errorf("failed to create session: %w", err)
	}
	defer session.Close()

	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr

	if err := session.Run(cmd); err != nil {
		combined := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
		return combined, fmt.Errorf("command failed: %w\noutput: %s", err, combined)
	}

	return strings.TrimSpace(stdout.String()), nil
}

// RunScript pipes a script into bash -s and streams output to the provided writer.
// If out is nil, output is discarded.
func (s *SSHSession) RunScript(script string, out io.Writer) error {
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

	if err := session.Run("bash -s"); err != nil {
		return fmt.Errorf("script execution failed: %w", err)
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
	osInfo, _ := s.RunCommand("cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
	if osInfo == "" {
		osInfo, _ = s.RunCommand("uname -s")
	}
	arch, _ := s.RunCommand("uname -m")
	memStr, _ := s.RunCommand("grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}'")

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
	result := make(map[int]bool, len(ports))
	for _, p := range ports {
		result[p] = false
	}

	output, err := s.RunCommand("ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null")
	if err != nil {
		return result, nil // non-fatal
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
