package digitalocean

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

// newCompensationFakeServer installs a fake DigitalOcean API serving the
// minimal create path and counting droplet DELETE calls. The global base URL
// and the provider's HTTP client are swapped for the duration of the test.
func newCompensationFakeServer(t *testing.T, provider *Provider, deleteStatus int) *atomic.Int32 {
	t.Helper()

	deleteCalls := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/account/keys":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"ssh_keys":[]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/account/keys":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"ssh_key":{"id":7319}}`))
		case r.Method == http.MethodPost && r.URL.Path == "/droplets":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"droplet":{"id":424242,"name":"test-node","status":"new","created_at":"2026-07-13T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"}}}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/droplets/424242":
			deleteCalls.Add(1)
			if deleteStatus == http.StatusInternalServerError {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"message":"boom"}`))
				return
			}
			w.WriteHeader(deleteStatus)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	originalBaseURL := baseURL
	baseURL = server.URL
	provider.client = server.Client()
	t.Cleanup(func() {
		baseURL = originalBaseURL
	})

	return deleteCalls
}

// newCompensationTestEnv builds a provider whose node-record persistence is
// guaranteed to fail (the records directory path is occupied by a regular
// file, so the read-modify-write cycle fails with ENOTDIR) plus a fake
// DigitalOcean API that records DELETE calls.
func newCompensationTestEnv(t *testing.T, deleteStatus int) (*Provider, *atomic.Int32) {
	t.Helper()

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{
		Provider: "digitalocean",
		APIKey:   "test-key",
	})

	// Occupy the parent directory of nodesPath with a regular file so both
	// reading and writing the records file fails with ENOTDIR.
	if err := os.MkdirAll(filepath.Dir(filepath.Dir(provider.nodesPath)), 0o755); err != nil {
		t.Fatalf("mkdir data dir: %v", err)
	}
	if err := os.WriteFile(filepath.Dir(provider.nodesPath), []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("occupy records dir path: %v", err)
	}

	return provider, newCompensationFakeServer(t, provider, deleteStatus)
}

// newSaveFailCompensationTestEnv reaches the write half of persistence: the
// empty records file loads successfully, but its read-only parent directory
// prevents the atomic writer from creating its same-directory temporary file.
func newSaveFailCompensationTestEnv(t *testing.T, deleteStatus int) (*Provider, *atomic.Int32) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("file permissions do not block root; cannot simulate a write failure")
	}

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-key"})
	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o755); err != nil {
		t.Fatalf("mkdir nodes dir: %v", err)
	}
	if err := os.WriteFile(provider.nodesPath, nil, 0o400); err != nil {
		t.Fatalf("write read-only nodes file: %v", err)
	}
	nodesDir := filepath.Dir(provider.nodesPath)
	if err := os.Chmod(nodesDir, 0o500); err != nil {
		t.Fatalf("make nodes directory read-only: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(nodesDir, 0o700) })
	return provider, newCompensationFakeServer(t, provider, deleteStatus)
}

func compensationCreateOpts() *cloud.CreateInstanceOptions {
	return &cloud.CreateInstanceOptions{
		Label:  "test-node",
		Region: "sgp1",
		Plan:   "s-1vcpu-1gb",
	}
}

func TestCreateInstanceCompensatesWhenPersistFails(t *testing.T) {
	provider, deleteCalls := newCompensationTestEnv(t, http.StatusNoContent)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	instance, err := provider.CreateInstance(ctx, compensationCreateOpts())
	if err == nil {
		t.Fatalf("expected error, got instance %#v", instance)
	}
	if deleteCalls.Load() != 1 {
		t.Fatalf("expected exactly one compensating DELETE, got %d", deleteCalls.Load())
	}
	if !strings.Contains(err.Error(), "cloud-do-424242") {
		t.Fatalf("error should name the instance id, got: %v", err)
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("error should say the droplet was rolled back, got: %v", err)
	}
}

func TestCreateInstanceCompensatesWhenNodeRecordSaveFails(t *testing.T) {
	provider, deleteCalls := newSaveFailCompensationTestEnv(t, http.StatusNoContent)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	instance, err := provider.CreateInstance(ctx, compensationCreateOpts())
	if err == nil {
		t.Fatalf("expected error, got instance %#v", instance)
	}
	if deleteCalls.Load() != 1 {
		t.Fatalf("expected exactly one compensating DELETE, got %d", deleteCalls.Load())
	}
	if !strings.Contains(err.Error(), "cloud-do-424242") || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("expected actionable rollback error, got: %v", err)
	}
	data, readErr := os.ReadFile(provider.nodesPath)
	if readErr != nil {
		t.Fatalf("read nodes file: %v", readErr)
	}
	if len(data) != 0 {
		t.Fatalf("records file should remain empty after failed save, got %d bytes", len(data))
	}
}

func TestCreateInstanceReportsWhenCompensationAlsoFails(t *testing.T) {
	provider, deleteCalls := newCompensationTestEnv(t, http.StatusInternalServerError)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	instance, err := provider.CreateInstance(ctx, compensationCreateOpts())
	if err == nil {
		t.Fatalf("expected error, got instance %#v", instance)
	}
	if deleteCalls.Load() != 1 {
		t.Fatalf("expected exactly one compensating DELETE attempt, got %d", deleteCalls.Load())
	}
	if !strings.Contains(err.Error(), "cloud-do-424242") {
		t.Fatalf("error should name the instance id, got: %v", err)
	}
	if !strings.Contains(err.Error(), "manually") {
		t.Fatalf("error should tell the user to delete manually, got: %v", err)
	}
}
