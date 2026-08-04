package digitalocean

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

// TestCreateInstanceAfterRestartLoadsAPIKeyFromDisk reproduces the real
// process-restart shape: a previous run saved the provider config (API key in
// the secret store, sanitized JSON on disk), then the process restarts and the
// defaults registry constructs the provider with New(nil). A direct
// CreateInstance — without any prior GetConfig/SaveConfig — must still send
// the stored API key, not an empty "Bearer " header.
func TestCreateInstanceAfterRestartLoadsAPIKeyFromDisk(t *testing.T) {
	const apiKey = "dop_v1_restart_key"

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	// First process life: the operator saves the config once. The API key
	// lands in the secret store; the on-disk JSON is sanitized.
	seed := New(nil)
	if err := seed.SaveConfig(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: apiKey}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	rawConfig, err := os.ReadFile(seed.configPath)
	if err != nil {
		t.Fatalf("read saved config: %v", err)
	}
	if strings.Contains(string(rawConfig), apiKey) {
		t.Fatalf("on-disk config must not contain the plaintext API key (secret-store form expected): %s", rawConfig)
	}

	var mu sync.Mutex
	createAuth := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/droplets":
			mu.Lock()
			createAuth = r.Header.Get("Authorization")
			mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"droplet":{"id":555001,"name":"restart-node","status":"new","created_at":"2026-07-13T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"}}}`))
		case r.Method == http.MethodGet && r.URL.Path == "/droplets/555001":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"droplet":{"id":555001,"name":"restart-node","status":"active","created_at":"2026-07-13T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"},"networks":{"v4":[],"v6":[]}}}`))
		default:
			// ensureManagedSSHKey / firewall calls are best-effort; failing
			// them keeps the test fast without masking the auth assertion.
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })

	// Second process life: registry default shape — no API key injected.
	provider := New(nil)
	provider.client = server.Client()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	instance, err := provider.CreateInstance(ctx, &cloud.CreateInstanceOptions{
		Label:  "restart-node",
		Region: "sgp1",
		Plan:   "s-1vcpu-1gb",
		Extra: map[string]string{
			// Keep the post-create readiness waits from stalling the test:
			// the fake droplet never exposes an IP, so cap the wait at 1s and
			// skip the sing-box protocol probe entirely.
			"serviceReadyTimeoutSec": "1",
			"protocolProbeEnabled":   "false",
		},
	})
	if err != nil {
		t.Fatalf("CreateInstance: %v", err)
	}
	if instance == nil || instance.ID != "cloud-do-555001" {
		t.Fatalf("unexpected instance: %#v", instance)
	}

	mu.Lock()
	gotAuth := createAuth
	mu.Unlock()
	if gotAuth != "Bearer "+apiKey {
		t.Fatalf("create request Authorization = %q, want %q", gotAuth, "Bearer "+apiKey)
	}
}

// TestCreateInstanceWithoutAnyStoredKeyFailsBeforeAPICall covers the other
// half of the restart contract: with nothing on disk, the provider must fail
// with ErrMissingAPIKey instead of firing an empty "Bearer " request.
func TestCreateInstanceWithoutAnyStoredKeyFailsBeforeAPICall(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		http.NotFound(w, r)
	}))
	t.Cleanup(server.Close)

	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })

	provider := New(nil)
	provider.client = server.Client()

	_, err := provider.CreateInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label:  "n",
		Region: "sgp1",
		Plan:   "s-1vcpu-1gb",
	})
	if err == nil {
		t.Fatal("expected error for missing API key")
	}
	if !errors.Is(err, cloud.ErrMissingAPIKey) {
		t.Fatalf("expected ErrMissingAPIKey, got: %v", err)
	}
	if requests != 0 {
		t.Fatalf("expected no API requests without a key, got %d", requests)
	}
}
