package digitalocean

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestSameAuthorizedKey(t *testing.T) {
	a := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYMATERIAL comment-one"
	b := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYMATERIAL different-comment"
	c := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERMATERIAL comment"
	if !sameAuthorizedKey(a, b) {
		t.Fatal("same key material with different comments must match")
	}
	if sameAuthorizedKey(a, c) {
		t.Fatal("different key material must not match")
	}
	if sameAuthorizedKey("garbage", a) {
		t.Fatal("malformed key must not match")
	}
}

// Mirrors the keygen path in ensureManagedSSHKey: generate ed25519, marshal to
// an OpenSSH PEM, parse it back, and confirm the derived public key is stable
// and self-consistent.
func TestManagedKeyRoundTrip(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(priv, managedSSHKeyName)
	if err != nil {
		t.Fatal(err)
	}
	privPEM := string(pem.EncodeToMemory(block))

	derived, err := publicKeyFromPEM(privPEM)
	if err != nil {
		t.Fatalf("publicKeyFromPEM: %v", err)
	}
	if !strings.HasPrefix(derived, "ssh-ed25519 ") {
		t.Fatalf("expected ed25519 authorized key, got %q", derived)
	}

	// The authorized key derived from the PEM must match the one derived
	// straight from the public key (this is what ensureKeyRegistered compares).
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	fromPub := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub)))
	if !sameAuthorizedKey(derived, fromPub) {
		t.Fatalf("authorized key mismatch:\n  fromPEM=%s\n  fromPub=%s", derived, fromPub)
	}
}
