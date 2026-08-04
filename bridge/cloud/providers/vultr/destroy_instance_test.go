package vultr

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

// newDestroyFakeServer installs a fake Vultr API whose DELETE /instances/:id
// answers with the given status. The global API base URL / HTTP client are
// swapped for the duration of the test.
func newDestroyFakeServer(t *testing.T, deleteStatus int) {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete && r.URL.Path == "/instances/inst-gone" {
			if deleteStatus == http.StatusNotFound {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":"Instance not found"}`))
				return
			}
			w.WriteHeader(deleteStatus)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(server.Close)

	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})
}

// TestDestroyInstanceTreats404AsAlreadyGone: a Vultr instance that was
// already deleted out-of-band (console, expired trial, etc.) makes the real
// DELETE call 404. That still satisfies "this instance should no longer
// exist", so DestroyInstance must succeed and purge the stale local record —
// not leave it permanently un-deletable from the UI.
func TestDestroyInstanceTreats404AsAlreadyGone(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	newDestroyFakeServer(t, http.StatusNotFound)

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	if err := provider.persistNodeRecord("inst-gone", nodeRecord{InstanceID: "inst-gone", Label: "stale-node", Region: "lax"}); err != nil {
		t.Fatalf("seed node record: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := provider.DestroyInstance(ctx, "inst-gone"); err != nil {
		t.Fatalf("DestroyInstance should treat 404 as success, got: %v", err)
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if _, ok := records["inst-gone"]; ok {
		t.Fatalf("stale local record for inst-gone should have been purged")
	}
}

// TestDestroyInstancePropagatesOtherErrors ensures the fix is narrowly
// scoped to 404: a real API failure (e.g. auth/server error) must still be
// reported, not swallowed, and the local record must be kept for retry.
func TestDestroyInstancePropagatesOtherErrors(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	newDestroyFakeServer(t, http.StatusInternalServerError)

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	if err := provider.persistNodeRecord("inst-gone", nodeRecord{InstanceID: "inst-gone", Label: "stale-node", Region: "lax"}); err != nil {
		t.Fatalf("seed node record: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := provider.DestroyInstance(ctx, "inst-gone"); err == nil {
		t.Fatalf("expected DestroyInstance to fail on a real API error")
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if _, ok := records["inst-gone"]; !ok {
		t.Fatalf("local record must be kept when the destroy call genuinely fails")
	}
}
