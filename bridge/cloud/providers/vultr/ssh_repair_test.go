package vultr

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

func TestManagedSSHRepairCommandIsBoundedAndSerialized(t *testing.T) {
	for _, required := range []string{
		"flock -w 5",
		"timeout --signal=TERM --kill-after=10s 120s",
		vultrCloudInitUserDataPath,
	} {
		if !strings.Contains(managedSSHRepairCommand, required) {
			t.Fatalf("managed repair command is missing %q", required)
		}
	}
}

func TestRunRemoteDeploymentRepairHonorsContextDuringSSHHandshake(t *testing.T) {
	privatePEM, _, _ := generateVultrManagedKeyForTest(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = runRemoteDeploymentRepairAtAddress(ctx, listener.Addr().String(), privatePEM)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error=%v, want context deadline", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("SSH handshake ignored cancellation for %v", elapsed)
	}
	select {
	case conn := <-accepted:
		_ = conn.Close()
	default:
	}
}

func TestRunRemoteDeploymentRepairDoesNotEchoPrivateKeyInErrors(t *testing.T) {
	const sensitive = "PRIVATE-KEY-MATERIAL-MUST-NOT-LEAK"
	err := runRemoteDeploymentRepair(context.Background(), "127.0.0.1", sensitive)
	if err == nil {
		t.Fatal("expected invalid private-key error")
	}
	if strings.Contains(err.Error(), sensitive) {
		t.Fatalf("private key leaked in error: %v", err)
	}
}

func TestRunRemoteDeploymentRepairAcceptsNilContext(t *testing.T) {
	privatePEM, _, _ := generateVultrManagedKeyForTest(t)
	err := runRemoteDeploymentRepairAtAddress(nil, "127.0.0.1:0", privatePEM)
	if !errors.Is(err, errRemoteSSHConnection) {
		t.Fatalf("error=%v, want SSH connection failure", err)
	}
}
