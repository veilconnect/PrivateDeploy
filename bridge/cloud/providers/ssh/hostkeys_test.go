package ssh

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"path/filepath"
	"testing"

	gossh "golang.org/x/crypto/ssh"
)

func TestTrustOnFirstUseHostKeyCallbackPersistsNewKey(t *testing.T) {
	storePath := filepath.Join(t.TempDir(), "hostkeys.json")
	callback := trustOnFirstUseHostKeyCallback(storePath)
	publicKey := testSSHPublicKey(t)

	if err := callback("example.com:22", &net.TCPAddr{}, publicKey); err != nil {
		t.Fatalf("first use should trust host key: %v", err)
	}

	records, err := loadHostKeyRecords(storePath)
	if err != nil {
		t.Fatalf("load host key records: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 persisted host key, got %d", len(records))
	}
}

func TestTrustOnFirstUseHostKeyCallbackRejectsMismatchedKey(t *testing.T) {
	storePath := filepath.Join(t.TempDir(), "hostkeys.json")
	callback := trustOnFirstUseHostKeyCallback(storePath)

	if err := callback("example.com:22", &net.TCPAddr{}, testSSHPublicKey(t)); err != nil {
		t.Fatalf("seed host key: %v", err)
	}

	if err := callback("example.com:22", &net.TCPAddr{}, testSSHPublicKey(t)); err == nil {
		t.Fatal("expected mismatched key to be rejected")
	}
}

func testSSHPublicKey(t *testing.T) gossh.PublicKey {
	t.Helper()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := gossh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("create signer: %v", err)
	}
	return signer.PublicKey()
}
