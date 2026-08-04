package vultr

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

// newCompensationFakeServer installs a fake Vultr API serving the minimal
// create path and counting DELETE calls against the created instance. The
// global API base URL / HTTP client are swapped for the duration of the test.
func newCompensationFakeServer(t *testing.T, deleteStatus int) *atomic.Int32 {
	t.Helper()

	deleteCalls := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/plans":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"plans":[{"id":"vc2-1c-1gb","ram":512}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/os":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"os":[{"id":477,"name":"Debian 12 x64","family":"debian"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/instances":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"instance":{"id":"inst-orphan","label":"test-node","status":"pending","region":"nrt","created_at":"2026-07-13T00:00:00Z"}}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/instances/inst-orphan":
			deleteCalls.Add(1)
			if deleteStatus == http.StatusInternalServerError {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"message":"boom"}}`))
				return
			}
			w.WriteHeader(deleteStatus)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
		osCacheMu.Lock()
		osCache = nil
		osCacheTime = time.Time{}
		osCacheMu.Unlock()
	})

	return deleteCalls
}

// newCompensationTestEnv builds a provider whose node-record persistence is
// guaranteed to fail at the LOAD stage (the records directory path is occupied
// by a regular file) plus a fake Vultr API that records DELETE calls.
func newCompensationTestEnv(t *testing.T, deleteStatus int) (*Provider, *atomic.Int32) {
	t.Helper()

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	provider := New(&cloud.ProviderConfig{
		Provider: "vultr",
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

	return provider, newCompensationFakeServer(t, deleteStatus)
}

// newSaveFailCompensationTestEnv builds a provider whose node-record LOAD
// succeeds (an empty, readable records file) but whose final SAVE fails
// because the records directory cannot accept the atomic writer's temporary
// file. This exercises the second half of the persistence path, which the
// ENOTDIR env above never reaches.
func newSaveFailCompensationTestEnv(t *testing.T, deleteStatus int) (*Provider, *atomic.Int32) {
	t.Helper()

	if os.Geteuid() == 0 {
		t.Skip("file permissions do not block root; cannot simulate a write failure")
	}

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "test-key",
	})

	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o755); err != nil {
		t.Fatalf("mkdir nodes dir: %v", err)
	}
	// Empty file: loads as an empty record map, but its directory cannot accept
	// a same-directory temporary file for atomic replacement.
	if err := os.WriteFile(provider.nodesPath, nil, 0o400); err != nil {
		t.Fatalf("write read-only nodes file: %v", err)
	}
	nodesDir := filepath.Dir(provider.nodesPath)
	if err := os.Chmod(nodesDir, 0o500); err != nil {
		t.Fatalf("make nodes directory read-only: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(nodesDir, 0o700) })

	return provider, newCompensationFakeServer(t, deleteStatus)
}

func compensationCreateOpts() *cloud.CreateInstanceOptions {
	return &cloud.CreateInstanceOptions{
		Label:  "test-node",
		Region: "nrt",
		Plan:   "vc2-1c-1gb",
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
	if !strings.Contains(err.Error(), "inst-orphan") {
		t.Fatalf("error should name the instance id, got: %v", err)
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("error should say the instance was rolled back, got: %v", err)
	}
}

// TestCreateInstanceCompensationTreats404AsSuccess: a DELETE that answers 404
// means the instance is already gone — the rollback goal is met, so the error
// must report a successful rollback, not a failed compensation.
func TestCreateInstanceCompensationTreats404AsSuccess(t *testing.T) {
	provider, deleteCalls := newCompensationTestEnv(t, http.StatusNotFound)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	instance, err := provider.CreateInstance(ctx, compensationCreateOpts())
	if err == nil {
		t.Fatalf("expected error, got instance %#v", instance)
	}
	if deleteCalls.Load() != 1 {
		t.Fatalf("expected exactly one compensating DELETE, got %d", deleteCalls.Load())
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("404 on compensating delete must count as a successful rollback, got: %v", err)
	}
	if strings.Contains(err.Error(), "manually") {
		t.Fatalf("404 must not be reported as a failed compensation, got: %v", err)
	}
}

// TestCreateInstanceCompensatesWhenNodeRecordSaveFails covers the case where
// the record load succeeds but the final write to disk fails: the freshly
// created instance would be unusable, so the compensating delete must still
// fire.
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
	if !strings.Contains(err.Error(), "inst-orphan") {
		t.Fatalf("error should name the instance id, got: %v", err)
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("error should say the instance was rolled back, got: %v", err)
	}

	// The read-only records file must be untouched: no phantom record for the
	// rolled-back instance.
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
	if !strings.Contains(err.Error(), "inst-orphan") {
		t.Fatalf("error should name the instance id, got: %v", err)
	}
	if !strings.Contains(err.Error(), "manually") {
		t.Fatalf("error should tell the user to delete manually, got: %v", err)
	}
}
