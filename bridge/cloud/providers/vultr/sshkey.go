package vultr

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/pem"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
)

const (
	managedSSHKeyName  = "privatedeploy-managed"
	managedSSHKeyScope = "vultr-managed-ssh"
)

type vultrAccountSSHKey struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	PublicKey string `json:"ssh_key"`
}

// ensureManagedSSHKey creates or reuses PrivateDeploy's account-level Vultr
// SSH key. The private half never enters provider config, node records,
// request logs, or API payloads: it is kept only in the shared secret store.
//
// A process-wide mutex would not protect two concurrently running application
// processes, so the complete local-secret/account-key transaction is guarded
// by an OS file lock. This also makes the first concurrent deployment converge
// on one key and one Vultr API POST.
func (p *Provider) ensureManagedSSHKey(ctx context.Context) (id, privatePEM, fingerprint string, err error) {
	if _, err := p.ensureConfig(); err != nil {
		return "", "", "", err
	}

	lockPath := filepath.Join(filepath.Dir(filepath.Dir(p.configPath)), ".locks", "vultr-managed-ssh.lock")
	lock, err := acquireManagedSSHKeyProcessLock(ctx, lockPath)
	if err != nil {
		return "", "", "", err
	}
	defer lock.Close()

	privatePEM, err = cloud.LoadSecret(p.configPath, managedSSHKeyScope)
	if err == nil && strings.TrimSpace(privatePEM) != "" {
		privatePEM = strings.TrimSpace(privatePEM)
		publicKey, keyFingerprint, parseErr := managedPublicKeyFromPEM(privatePEM)
		if parseErr != nil {
			return "", "", "", fmt.Errorf("parse managed SSH recovery key: %w", parseErr)
		}
		id, err = p.ensureManagedKeyRegistered(ctx, publicKey)
		if err != nil {
			return "", "", "", err
		}
		return id, privatePEM, keyFingerprint, nil
	}
	if err != nil && !errors.Is(err, cloud.ErrSecretNotFound) {
		return "", "", "", err
	}

	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", "", fmt.Errorf("generate managed SSH recovery key: %w", err)
	}
	block, err := ssh.MarshalPrivateKey(private, managedSSHKeyName)
	if err != nil {
		return "", "", "", fmt.Errorf("encode managed SSH recovery key: %w", err)
	}
	privatePEM = strings.TrimSpace(string(pem.EncodeToMemory(block)))
	sshPublic, err := ssh.NewPublicKey(public)
	if err != nil {
		return "", "", "", fmt.Errorf("encode managed SSH public key: %w", err)
	}
	publicKey := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPublic)))
	fingerprint = ssh.FingerprintSHA256(sshPublic)

	// Persist first. If the API call is interrupted, the next attempt reuses
	// exactly this key instead of creating an unrecoverable orphan public key.
	if err := cloud.SaveSecret(p.configPath, managedSSHKeyScope, privatePEM); err != nil {
		return "", "", "", fmt.Errorf("store managed SSH recovery key: %w", err)
	}
	id, err = p.ensureManagedKeyRegistered(ctx, publicKey)
	if err != nil {
		return "", "", "", err
	}
	return id, privatePEM, fingerprint, nil
}

func managedPublicKeyFromPEM(privatePEM string) (authorizedKey, fingerprint string, err error) {
	signer, err := ssh.ParsePrivateKey([]byte(privatePEM))
	if err != nil {
		return "", "", err
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))), ssh.FingerprintSHA256(signer.PublicKey()), nil
}

func sameManagedAuthorizedKey(a, b string) bool {
	left, right := strings.Fields(a), strings.Fields(b)
	return len(left) >= 2 && len(right) >= 2 && left[0] == right[0] && left[1] == right[1]
}

func (p *Provider) ensureManagedKeyRegistered(ctx context.Context, authorizedKey string) (string, error) {
	keys, err := p.listAccountSSHKeys(ctx)
	if err != nil {
		return "", fmt.Errorf("list Vultr SSH keys: %w", err)
	}
	if id := findManagedAccountKey(keys, authorizedKey); id != "" {
		return id, nil
	}

	id, createErr := p.createAccountSSHKey(ctx, authorizedKey)
	if createErr == nil && id != "" {
		return id, nil
	}
	// A response can be lost after Vultr accepted the key, and a separate
	// account client can race outside our local lock. Re-list once; never POST
	// the same public key twice after an ambiguous response.
	if keys, listErr := p.listAccountSSHKeys(ctx); listErr == nil {
		if recoveredID := findManagedAccountKey(keys, authorizedKey); recoveredID != "" {
			return recoveredID, nil
		}
	}
	if createErr != nil {
		return "", fmt.Errorf("register Vultr managed SSH key: %w", createErr)
	}
	return "", fmt.Errorf("register Vultr managed SSH key: API returned an empty key id")
}

func findManagedAccountKey(keys []vultrAccountSSHKey, authorizedKey string) string {
	for _, key := range keys {
		if sameManagedAuthorizedKey(key.PublicKey, authorizedKey) {
			return strings.TrimSpace(key.ID)
		}
	}
	return ""
}

func (p *Provider) listAccountSSHKeys(ctx context.Context) ([]vultrAccountSSHKey, error) {
	res, err := p.apiRequest(ctx, "GET", "/ssh-keys?per_page=500", nil)
	if err != nil {
		return nil, err
	}
	var payload struct {
		SSHKeys []vultrAccountSSHKey `json:"ssh_keys"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}
	return payload.SSHKeys, nil
}

func (p *Provider) createAccountSSHKey(ctx context.Context, authorizedKey string) (string, error) {
	res, err := p.apiRequest(ctx, "POST", "/ssh-keys", map[string]string{
		"name":    managedSSHAccountKeyName(authorizedKey),
		"ssh_key": authorizedKey,
	})
	if err != nil {
		return "", err
	}
	var payload struct {
		SSHKey vultrAccountSSHKey `json:"ssh_key"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return "", err
	}
	return strings.TrimSpace(payload.SSHKey.ID), nil
}

func managedSSHAccountKeyName(authorizedKey string) string {
	// Different PrivateDeploy installations can legitimately use the same
	// Vultr account. A key-derived suffix avoids fixed-name collisions while
	// remaining stable across retries and process restarts.
	sum := sha256.Sum256([]byte(strings.TrimSpace(authorizedKey)))
	return fmt.Sprintf("%s-%x", managedSSHKeyName, sum[:6])
}
