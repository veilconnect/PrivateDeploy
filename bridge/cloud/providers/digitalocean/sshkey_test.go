package digitalocean

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"privatedeploy/bridge/cloud"
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

func TestEnsureManagedSSHKeyConcurrentCreatesOnce(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	const keyID = 7319
	var (
		apiMu       sync.Mutex
		accountKey  *doAccountKey
		createCount int
		apiErr      string
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			apiMu.Lock()
			apiErr = fmt.Sprintf("unexpected authorization header %q", r.Header.Get("Authorization"))
			apiMu.Unlock()
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/account/keys":
			// Widen the first-use race window: without serialization, many
			// callers observe an empty account before any POST completes.
			time.Sleep(10 * time.Millisecond)
			apiMu.Lock()
			keys := []doAccountKey(nil)
			if accountKey != nil {
				keys = append(keys, *accountKey)
			}
			apiMu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_keys": keys})

		case r.Method == http.MethodPost && r.URL.Path == "/account/keys":
			var request struct {
				Name      string `json:"name"`
				PublicKey string `json:"public_key"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			apiMu.Lock()
			createCount++
			created := doAccountKey{ID: keyID, Name: request.Name, PublicKey: request.PublicKey}
			accountKey = &created
			apiMu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_key": created})

		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })

	// Two independent Provider values model overlapping desktop processes: they
	// do not share the in-memory mutex, so only the file lock can serialize the
	// local-secret/account-key transaction.
	providers := []*Provider{
		New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"}),
		New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"}),
	}
	for _, provider := range providers {
		provider.client = server.Client()
	}

	const callers = 64
	type result struct {
		id          int
		privPEM     string
		fingerprint string
		err         error
	}
	results := make(chan result, callers)
	start := make(chan struct{})
	var callersWG sync.WaitGroup
	callersWG.Add(callers)
	for i := 0; i < callers; i++ {
		go func(provider *Provider) {
			defer callersWG.Done()
			<-start
			id, privPEM, fingerprint, err := provider.ensureManagedSSHKey(context.Background())
			results <- result{id: id, privPEM: privPEM, fingerprint: fingerprint, err: err}
		}(providers[i%len(providers)])
	}
	close(start)
	callersWG.Wait()
	close(results)

	var firstPEM string
	var firstFingerprint string
	for got := range results {
		if got.err != nil {
			t.Fatalf("ensureManagedSSHKey: %v", got.err)
		}
		if got.id != keyID {
			t.Fatalf("key ID = %d, want %d", got.id, keyID)
		}
		if strings.TrimSpace(got.privPEM) == "" {
			t.Fatal("ensureManagedSSHKey returned an empty private key")
		}
		if strings.TrimSpace(got.fingerprint) == "" {
			t.Fatal("ensureManagedSSHKey returned an empty fingerprint")
		}
		if firstPEM == "" {
			firstPEM = got.privPEM
			firstFingerprint = got.fingerprint
		} else if got.privPEM != firstPEM {
			t.Fatal("concurrent callers received different private keys")
		} else if got.fingerprint != firstFingerprint {
			t.Fatal("concurrent callers received different fingerprints")
		}
	}

	apiMu.Lock()
	gotCreateCount := createCount
	gotAPIErr := apiErr
	apiMu.Unlock()
	if gotAPIErr != "" {
		t.Fatal(gotAPIErr)
	}
	if gotCreateCount != 1 {
		t.Fatalf("DigitalOcean key create calls = %d, want exactly 1", gotCreateCount)
	}

	storedPEM, err := cloud.LoadSecret(providers[0].configPath, managedSSHKeyScope)
	if err != nil {
		t.Fatalf("load persisted managed key: %v", err)
	}
	if storedPEM != firstPEM {
		t.Fatal("persisted private key differs from the key returned to callers")
	}
}

func TestEnsureKeyRegisteredRecoversAcceptedCreateAfterLostResponse(t *testing.T) {
	const (
		keyID         = 8462
		authorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRECOVERABLEKEY privatedeploy"
	)
	var mu sync.Mutex
	listCalls := 0
	postCalls := 0
	accepted := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/account/keys":
			mu.Lock()
			listCalls++
			present := accepted
			mu.Unlock()
			keys := []doAccountKey(nil)
			if present {
				keys = append(keys, doAccountKey{ID: keyID, PublicKey: authorizedKey})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_keys": keys})
		case r.Method == http.MethodPost && r.URL.Path == "/account/keys":
			mu.Lock()
			postCalls++
			accepted = true
			mu.Unlock()
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"ssh_key":`)) // accepted, then response was truncated
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })

	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
	provider.client = server.Client()
	gotID, err := provider.ensureKeyRegistered(context.Background(), authorizedKey)
	if err != nil {
		t.Fatalf("ensureKeyRegistered: %v", err)
	}
	if gotID != keyID {
		t.Fatalf("key id = %d, want %d", gotID, keyID)
	}
	mu.Lock()
	gotLists, gotPosts := listCalls, postCalls
	mu.Unlock()
	if gotLists != 2 || gotPosts != 1 {
		t.Fatalf("list calls=%d post calls=%d, want 2 and 1", gotLists, gotPosts)
	}
}

func TestCreateInstanceManagedSSHSecretSaveFailureStopsBeforeAnyPOST(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.Error(w, "unexpected cloud request", http.StatusInternalServerError)
	}))
	defer server.Close()
	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })

	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
	provider.client = server.Client()
	provider.saveManagedSSHSecret = func(string, string, string) error {
		return errors.New("injected secret persistence failure")
	}

	instance, err := provider.CreateInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label:  "must-not-create",
		Region: "nyc3",
		Plan:   "s-1vcpu-1gb",
	})
	if err == nil || instance != nil {
		t.Fatalf("CreateInstance = %#v, %v; want pre-submit failure", instance, err)
	}
	if !strings.Contains(err.Error(), "prepare DigitalOcean managed SSH recovery key before create") {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := requests.Load(); got != 0 {
		t.Fatalf("cloud API requests after private-key save failure = %d, want 0", got)
	}
}

func TestCreateInstanceInvalidOptionsStopBeforeLocalOrCloudMutation(t *testing.T) {
	tests := []struct {
		name string
		opts *cloud.CreateInstanceOptions
	}{
		{name: "nil", opts: nil},
		{name: "empty label", opts: &cloud.CreateInstanceOptions{Region: "nyc3", Plan: "s-1vcpu-1gb"}},
		{name: "blank region", opts: &cloud.CreateInstanceOptions{Label: "node", Region: " \t", Plan: "s-1vcpu-1gb"}},
		{name: "blank plan", opts: &cloud.CreateInstanceOptions{Label: "node", Region: "nyc3", Plan: "\n"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			basePath := t.TempDir()
			t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
			t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

			var requests, secretSaves, realityGenerations atomic.Int32
			provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
			provider.client = &http.Client{Transport: doCreateRoundTripFunc(func(*http.Request) (*http.Response, error) {
				requests.Add(1)
				return doTestResponse(http.StatusInternalServerError, `{}`), nil
			})}
			provider.saveManagedSSHSecret = func(string, string, string) error {
				secretSaves.Add(1)
				return nil
			}
			provider.generateRealityKeyPair = func() (string, string, error) {
				realityGenerations.Add(1)
				return "private", "public", nil
			}

			instance, err := provider.CreateInstance(context.Background(), test.opts)
			if err == nil || instance != nil {
				t.Fatalf("CreateInstance = %#v, %v; want validation failure", instance, err)
			}
			if requests.Load() != 0 || secretSaves.Load() != 0 || realityGenerations.Load() != 0 {
				t.Fatalf("invalid input caused requests=%d secret saves=%d reality generations=%d", requests.Load(), secretSaves.Load(), realityGenerations.Load())
			}
		})
	}
}

func TestCreateInstanceRealityKeyFailureStopsBeforeLocalOrCloudMutation(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	var requests, secretSaves atomic.Int32
	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
	provider.client = &http.Client{Transport: doCreateRoundTripFunc(func(*http.Request) (*http.Response, error) {
		requests.Add(1)
		return doTestResponse(http.StatusInternalServerError, `{}`), nil
	})}
	provider.saveManagedSSHSecret = func(string, string, string) error {
		secretSaves.Add(1)
		return nil
	}
	provider.generateRealityKeyPair = func() (string, string, error) {
		return "", "", errors.New("injected entropy failure")
	}
	// Avoid an unrelated live Reality-target probe in this local preflight test.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	instance, err := provider.CreateInstance(ctx, &cloud.CreateInstanceOptions{
		Label:  "must-not-create",
		Region: "nyc3",
		Plan:   "s-1vcpu-1gb",
	})
	if err == nil || instance != nil {
		t.Fatalf("CreateInstance = %#v, %v; want local key-generation failure", instance, err)
	}
	if !strings.Contains(err.Error(), "failed to generate reality key pair before create") {
		t.Fatalf("unexpected error: %v", err)
	}
	if requests.Load() != 0 || secretSaves.Load() != 0 {
		t.Fatalf("Reality key failure caused requests=%d secret saves=%d, want zero", requests.Load(), secretSaves.Load())
	}
}
