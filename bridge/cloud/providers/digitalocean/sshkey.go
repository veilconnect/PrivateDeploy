package digitalocean

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
)

const (
	managedSSHKeyName  = "privatedeploy-managed"
	managedSSHKeyScope = "do-managed-ssh" // secret-store scope for the private key
)

// ensureManagedSSHKey returns the DigitalOcean account SSH key ID and the PEM
// private key for PrivateDeploy's managed key, provisioning it on first use.
//
// Why this exists: DigitalOcean's API neither returns a droplet's user-data nor
// lets you attach an SSH key to a running droplet. So to ever recover a node's
// credentials after the local record is lost, we must (a) hold a private key
// and (b) attach its public key to every droplet at create time. The private
// key lives in the OS keyring (same store as API keys); the public key is
// registered on the DO account under a fixed name. This is a deliberate,
// DO-only trade-off — it adds a persistent root credential to the account in
// exchange for recoverability.
func (p *Provider) ensureManagedSSHKey(ctx context.Context) (int, string, error) {
	if p.config == nil || strings.TrimSpace(p.config.APIKey) == "" {
		return 0, "", cloud.ErrMissingAPIKey
	}

	if privPEM, err := cloud.LoadSecret(p.configPath, managedSSHKeyScope); err == nil && strings.TrimSpace(privPEM) != "" {
		authorized, perr := publicKeyFromPEM(privPEM)
		if perr != nil {
			return 0, "", perr
		}
		id, rerr := p.ensureKeyRegistered(ctx, authorized)
		if rerr != nil {
			return 0, "", rerr
		}
		return id, privPEM, nil
	} else if err != nil && !errors.Is(err, cloud.ErrSecretNotFound) {
		return 0, "", err
	}

	// First use: generate a fresh ed25519 key.
	pubKey, privKey, gerr := ed25519.GenerateKey(rand.Reader)
	if gerr != nil {
		return 0, "", gerr
	}
	pemBlock, merr := ssh.MarshalPrivateKey(privKey, managedSSHKeyName)
	if merr != nil {
		return 0, "", merr
	}
	privPEM := string(pem.EncodeToMemory(pemBlock))

	sshPub, nerr := ssh.NewPublicKey(pubKey)
	if nerr != nil {
		return 0, "", nerr
	}
	authorized := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub)))

	id, rerr := p.ensureKeyRegistered(ctx, authorized)
	if rerr != nil {
		return 0, "", rerr
	}
	if serr := cloud.SaveSecret(p.configPath, managedSSHKeyScope, privPEM); serr != nil {
		return 0, "", serr
	}
	return id, privPEM, nil
}

func publicKeyFromPEM(privPEM string) (string, error) {
	signer, err := ssh.ParsePrivateKey([]byte(privPEM))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))), nil
}

type doAccountKey struct {
	ID        int    `json:"id"`
	Name      string `json:"name"`
	PublicKey string `json:"public_key"`
}

// ensureKeyRegistered makes sure authorizedKey exists on the DO account,
// returning its key ID. Idempotent: matches an existing key by its public-key
// material before creating a new one.
func (p *Provider) ensureKeyRegistered(ctx context.Context, authorizedKey string) (int, error) {
	keys, err := p.listAccountKeys(ctx)
	if err != nil {
		return 0, err
	}
	for _, k := range keys {
		if sameAuthorizedKey(k.PublicKey, authorizedKey) {
			return k.ID, nil
		}
	}
	return p.createAccountKey(ctx, managedSSHKeyName, authorizedKey)
}

// sameAuthorizedKey compares the type+material of two authorized_keys lines,
// ignoring any trailing comment.
func sameAuthorizedKey(a, b string) bool {
	fa, fb := strings.Fields(a), strings.Fields(b)
	if len(fa) < 2 || len(fb) < 2 {
		return false
	}
	return fa[0] == fb[0] && fa[1] == fb[1]
}

func (p *Provider) listAccountKeys(ctx context.Context) ([]doAccountKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/account/keys?per_page=200", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: list keys status %d: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}
	var out struct {
		SSHKeys []doAccountKey `json:"ssh_keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.SSHKeys, nil
}

func (p *Provider) createAccountKey(ctx context.Context, name, authorizedKey string) (int, error) {
	body, _ := json.Marshal(map[string]string{"name": name, "public_key": authorizedKey})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/account/keys", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("%w: create key status %d: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(raw))
	}
	var out struct {
		SSHKey doAccountKey `json:"ssh_key"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, err
	}
	return out.SSHKey.ID, nil
}
