package digitalocean

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
)

func testManagedSSHKey(t *testing.T) (ssh.PublicKey, string) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPublicKey, err := ssh.NewPublicKey(publicKey)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(privateKey, "privatedeploy-repair-test")
	if err != nil {
		t.Fatal(err)
	}
	return sshPublicKey, string(pem.EncodeToMemory(block))
}

type repairSSHTestServer struct {
	address  string
	commands <-chan string
}

func startRepairSSHTestServer(
	t *testing.T,
	clientPublicKey ssh.PublicKey,
	handleExec func(ssh.Channel, string),
) repairSSHTestServer {
	t.Helper()
	_, hostPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	hostSigner, err := ssh.NewSignerFromKey(hostPrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	serverConfig := &ssh.ServerConfig{
		PublicKeyCallback: func(_ ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if !bytes.Equal(key.Marshal(), clientPublicKey.Marshal()) {
				return nil, errors.New("unexpected client key")
			}
			return nil, nil
		},
	}
	serverConfig.AddHostKey(hostSigner)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	commands := make(chan string, 1)

	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		serverConnection, channels, requests, handshakeErr := ssh.NewServerConn(connection, serverConfig)
		if handshakeErr != nil {
			return
		}
		defer serverConnection.Close()
		go ssh.DiscardRequests(requests)
		for newChannel := range channels {
			if newChannel.ChannelType() != "session" {
				_ = newChannel.Reject(ssh.UnknownChannelType, "session required")
				continue
			}
			channel, channelRequests, channelErr := newChannel.Accept()
			if channelErr != nil {
				return
			}
			for request := range channelRequests {
				if request.Type != "exec" {
					_ = request.Reply(false, nil)
					continue
				}
				var payload struct {
					Command string
				}
				if ssh.Unmarshal(request.Payload, &payload) != nil {
					_ = request.Reply(false, nil)
					_ = channel.Close()
					return
				}
				_ = request.Reply(true, nil)
				commands <- payload.Command
				handleExec(channel, payload.Command)
				return
			}
		}
	}()

	return repairSSHTestServer{address: listener.Addr().String(), commands: commands}
}

func finishRepairSSHCommand(channel ssh.Channel, status uint32) {
	_, _ = channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{Status: status}))
	_ = channel.Close()
}

func TestRerunRemoteUserDataUsesLockedTimedConstantCommand(t *testing.T) {
	clientPublicKey, privatePEM := testManagedSSHKey(t)
	server := startRepairSSHTestServer(t, clientPublicKey, func(channel ssh.Channel, _ string) {
		// A noisy remote script must not cause an unbounded client-side buffer.
		_, _ = channel.Write(bytes.Repeat([]byte("x"), managedUserDataOutputLimit*4))
		finishRepairSSHCommand(channel, 0)
	})

	if err := rerunRemoteUserData(context.Background(), server.address, privatePEM); err != nil {
		t.Fatalf("rerunRemoteUserData: %v", err)
	}
	select {
	case command := <-server.commands:
		for _, required := range []string{
			"flock --exclusive --nonblock --conflict-exit-code 75 9",
			"timeout --signal=TERM --kill-after=15s 180s",
			"tail -c 32768",
			cloudInitUserDataPath,
		} {
			if !strings.Contains(command, required) {
				t.Fatalf("remote repair command is missing %q:\n%s", required, command)
			}
		}
		if strings.Contains(command, privatePEM) {
			t.Fatal("remote command leaked the managed private key")
		}
	case <-time.After(time.Second):
		t.Fatal("SSH server did not receive a repair command")
	}
}

func TestRerunRemoteUserDataDoesNotLeakRemoteOutputInError(t *testing.T) {
	clientPublicKey, privatePEM := testManagedSSHKey(t)
	const remoteSecret = "api-token-and-proxy-password-must-not-leak"
	server := startRepairSSHTestServer(t, clientPublicKey, func(channel ssh.Channel, _ string) {
		_, _ = channel.Stderr().Write([]byte(remoteSecret))
		finishRepairSSHCommand(channel, 42)
	})

	err := rerunRemoteUserData(context.Background(), server.address, privatePEM)
	if err == nil || !strings.Contains(err.Error(), "status 42") {
		t.Fatalf("rerun error = %v, want generic exit status", err)
	}
	if strings.Contains(err.Error(), remoteSecret) {
		t.Fatalf("remote secret leaked in error: %v", err)
	}
}

func TestRerunRemoteUserDataHonorsContextCancellation(t *testing.T) {
	clientPublicKey, privatePEM := testManagedSSHKey(t)
	releaseServer := make(chan struct{})
	server := startRepairSSHTestServer(t, clientPublicKey, func(channel ssh.Channel, _ string) {
		<-releaseServer
		finishRepairSSHCommand(channel, 0)
	})

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- rerunRemoteUserData(ctx, server.address, privatePEM)
	}()
	select {
	case <-server.commands:
		cancel()
	case <-time.After(time.Second):
		close(releaseServer)
		t.Fatal("SSH server did not receive a repair command")
	}

	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("rerun cancellation error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		close(releaseServer)
		t.Fatal("SSH repair did not stop promptly after cancellation")
	}
	close(releaseServer)
}

func TestBoundedSSHOutputDiscardsBeyondLimit(t *testing.T) {
	output := newBoundedSSHOutput(8)
	payload := []byte("secret-output-that-must-not-be-retained")
	written, err := output.Write(payload)
	if err != nil || written != len(payload) {
		t.Fatalf("Write() = %d, %v", written, err)
	}
	accepted, truncated := output.stats()
	if accepted != 8 || !truncated {
		t.Fatalf("output stats = accepted %d, truncated %v", accepted, truncated)
	}
}

func TestRerunManagedUserDataDoesNotProvisionAKeyForExistingDroplet(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", t.TempDir())
	provider := New(nil)

	err := provider.rerunManagedUserData(context.Background(), "cloud-do-123", "203.0.113.10")
	if err == nil || !strings.Contains(err.Error(), "predates the PrivateDeploy managed SSH recovery key") {
		t.Fatalf("rerunManagedUserData error = %v", err)
	}
	// The repair path intentionally calls LoadSecret, not ensureManagedSSHKey:
	// registering a fresh account key cannot attach it to an existing droplet.
	if _, loadErr := cloud.LoadSecret(provider.configPath, managedSSHKeyScope); !errors.Is(loadErr, cloud.ErrSecretNotFound) {
		t.Fatalf("repair path unexpectedly provisioned a new managed key: %v", loadErr)
	}
}

func TestRerunManagedUserDataRejectsChangedPrivateKey(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", t.TempDir())
	provider := New(nil)

	attachedPublic, _ := testManagedSSHKey(t)
	_, currentPrivatePEM := testManagedSSHKey(t)
	const instanceID = "cloud-do-456"
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records[instanceID] = nodeRecord{
			ManagedSSHKeyFingerprint: ssh.FingerprintSHA256(attachedPublic),
		}
		return true, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := cloud.SaveSecret(provider.configPath, managedSSHKeyScope, currentPrivatePEM); err != nil {
		t.Fatal(err)
	}

	err := provider.rerunManagedUserData(context.Background(), instanceID, "203.0.113.10")
	if err == nil || !strings.Contains(err.Error(), "no longer matches this droplet") {
		t.Fatalf("rerunManagedUserData error = %v, want fingerprint mismatch", err)
	}
}
