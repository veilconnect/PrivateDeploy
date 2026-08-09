package vultr

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
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

func generateVultrManagedKeyForTest(t *testing.T) (privatePEM, authorizedKey, fingerprint string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(private, managedSSHKeyName)
	if err != nil {
		t.Fatal(err)
	}
	sshPublic, err := ssh.NewPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(pem.EncodeToMemory(block))),
		strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPublic))),
		ssh.FingerprintSHA256(sshPublic)
}

func useVultrTestServer(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(handler)
	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
		server.Close()
	})
	return server
}

func TestSameManagedAuthorizedKeyIgnoresComment(t *testing.T) {
	a := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYMATERIAL first"
	b := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYMATERIAL second"
	c := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHER other"
	if !sameManagedAuthorizedKey(a, b) {
		t.Fatal("matching SSH key material with a different comment must be reused")
	}
	if sameManagedAuthorizedKey(a, c) || sameManagedAuthorizedKey("invalid", a) {
		t.Fatal("different or malformed SSH keys must not match")
	}
}

func TestEnsureManagedSSHKeyConcurrentProvidersCreateOnce(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	var (
		apiMu       sync.Mutex
		accountKey  *vultrAccountSSHKey
		createCount int
		apiErr      string
	)
	useVultrTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			apiMu.Lock()
			apiErr = fmt.Sprintf("unexpected authorization header %q", r.Header.Get("Authorization"))
			apiMu.Unlock()
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/ssh-keys":
			time.Sleep(5 * time.Millisecond)
			apiMu.Lock()
			keys := []vultrAccountSSHKey(nil)
			if accountKey != nil {
				keys = append(keys, *accountKey)
			}
			apiMu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_keys": keys})
		case r.Method == http.MethodPost && r.URL.Path == "/ssh-keys":
			var request struct {
				Name      string `json:"name"`
				PublicKey string `json:"ssh_key"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			apiMu.Lock()
			if !strings.HasPrefix(request.Name, managedSSHKeyName+"-") {
				apiErr = fmt.Sprintf("managed key name %q has no key-derived suffix", request.Name)
			}
			createCount++
			created := vultrAccountSSHKey{ID: "key-managed", Name: request.Name, PublicKey: request.PublicKey}
			accountKey = &created
			apiMu.Unlock()
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_key": created})
		default:
			http.NotFound(w, r)
		}
	}))

	const callers = 48
	type result struct {
		id          string
		privatePEM  string
		fingerprint string
		err         error
	}
	results := make(chan result, callers)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			// Deliberately use separate Provider values: the filesystem lock must
			// serialize more than calls on one receiver.
			provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})
			id, privatePEM, fingerprint, err := provider.ensureManagedSSHKey(context.Background())
			results <- result{id: id, privatePEM: privatePEM, fingerprint: fingerprint, err: err}
		}()
	}
	close(start)
	wg.Wait()
	close(results)

	var first result
	for got := range results {
		if got.err != nil {
			t.Fatalf("ensureManagedSSHKey: %v", got.err)
		}
		if got.id != "key-managed" || got.privatePEM == "" || got.fingerprint == "" {
			t.Fatalf("incomplete managed key result: id=%q private=%t fingerprint=%q", got.id, got.privatePEM != "", got.fingerprint)
		}
		if first.privatePEM == "" {
			first = got
		} else if got.privatePEM != first.privatePEM || got.fingerprint != first.fingerprint {
			t.Fatal("concurrent providers returned different managed keys")
		}
	}
	apiMu.Lock()
	gotCreateCount, gotAPIErr := createCount, apiErr
	apiMu.Unlock()
	if gotAPIErr != "" {
		t.Fatal(gotAPIErr)
	}
	if gotCreateCount != 1 {
		t.Fatalf("POST /ssh-keys count=%d, want exactly 1", gotCreateCount)
	}

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})
	stored, err := cloud.LoadSecret(provider.configPath, managedSSHKeyScope)
	if err != nil {
		t.Fatalf("load managed SSH private key: %v", err)
	}
	if stored != first.privatePEM {
		t.Fatal("secret store key differs from the key returned to deploy callers")
	}
}

func TestCreateVultrInstanceAttachesManagedAndUserKeys(t *testing.T) {
	var captured []string
	useVultrTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			SSHKeyIDs []string `json:"sshkey_id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		captured = payload.SSHKeyIDs
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"instance":{"id":"inst-keyed"}}`))
	}))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})
	_, _, err := provider.createVultrInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label: "keyed", Region: "ewr", Plan: "vc2-1c-1gb", SSHKeyID: "user-key",
	}, []int{477}, "#!/bin/sh", "managed-key")
	if err != nil {
		t.Fatalf("createVultrInstance: %v", err)
	}
	if strings.Join(captured, ",") != "managed-key,user-key" {
		t.Fatalf("sshkey_id=%v, want managed and user key", captured)
	}
}

func TestCreateInstanceStopsBeforeBillablePostWhenManagedKeyCannotBePrepared(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	var instancePosts atomic.Int32
	useVultrTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/plans":
			_, _ = w.Write([]byte(`{"plans":[{"id":"vc2-1c-1gb","ram":512}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/os":
			_, _ = w.Write([]byte(`{"os":[{"id":477,"name":"Debian 12 x64","family":"debian"}]}`))
		case r.URL.Path == "/ssh-keys":
			http.Error(w, "key API unavailable", http.StatusServiceUnavailable)
		case r.Method == http.MethodPost && r.URL.Path == "/instances":
			instancePosts.Add(1)
			http.Error(w, "must not be called", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})
	instance, err := provider.CreateInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label: "safe", Region: "ewr", Plan: "vc2-1c-1gb",
	})
	if err == nil || instance != nil {
		t.Fatalf("expected pre-create key error, instance=%#v err=%v", instance, err)
	}
	if got := instancePosts.Load(); got != 0 {
		t.Fatalf("POST /instances count=%d, want 0 when recovery key setup fails", got)
	}
}
