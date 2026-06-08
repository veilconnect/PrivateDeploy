package ssh

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"testing"

	gossh "golang.org/x/crypto/ssh"
)

func TestPasswordAuth_ReturnsNonNil(t *testing.T) {
	auth := PasswordAuth("secret")
	if auth == nil {
		t.Error("PasswordAuth should return non-nil AuthMethod")
	}
}

func TestPrivateKeyAuth_InvalidKey(t *testing.T) {
	_, err := PrivateKeyAuth([]byte("not a real key"))
	if err == nil {
		t.Error("expected error for invalid PEM key")
	}
}

func TestPrivateKeyAuth_ValidKey(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("key generation failed: %v", err)
	}

	pemBlock, err := gossh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	pemBytes := pem.EncodeToMemory(pemBlock)

	auth, err := PrivateKeyAuth(pemBytes)
	if err != nil {
		t.Fatalf("PrivateKeyAuth failed: %v", err)
	}
	if auth == nil {
		t.Error("expected non-nil AuthMethod")
	}
}

func TestNewSession_InvalidHost(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping network test in short mode")
	}
	auth := PasswordAuth("password")
	_, err := NewSession("192.0.2.1", 22, "root", auth)
	if err == nil {
		t.Error("expected error connecting to non-routable host")
	}
}

func TestSSHSession_Close_Nil(t *testing.T) {
	s := &SSHSession{client: nil}
	err := s.Close()
	if err != nil {
		t.Errorf("Close on nil client should not error: %v", err)
	}
}

func TestServerInfo_Fields(t *testing.T) {
	info := &ServerInfo{
		OS:     "Debian GNU/Linux 11",
		Arch:   "x86_64",
		Memory: 1024,
	}
	if info.OS == "" || info.Arch == "" || info.Memory <= 0 {
		t.Errorf("unexpected ServerInfo: %+v", info)
	}
}
