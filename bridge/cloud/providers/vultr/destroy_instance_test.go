package vultr

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

const testVultrDestroyID = "11111111-2222-4333-8444-555555555555"

// newDestroyFakeServer installs a fake Vultr API whose DELETE /instances/:id
// answers with the given status. The global API base URL / HTTP client are
// swapped for the duration of the test.
func newDestroyFakeServer(t *testing.T, deleteStatus int) {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/firewalls" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"firewall_groups":[]}`))
			return
		}
		if r.Method == http.MethodGet && r.URL.Path == "/instances/"+testVultrDestroyID {
			if deleteStatus == http.StatusNotFound {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":"Instance not found"}`))
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"instance":{"id":"` + testVultrDestroyID + `"}}`))
			return
		}
		if r.Method == http.MethodDelete && r.URL.Path == "/instances/"+testVultrDestroyID {
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
	if err := provider.persistNodeRecord(testVultrDestroyID, nodeRecord{InstanceID: testVultrDestroyID, Label: "stale-node", Region: "lax"}); err != nil {
		t.Fatalf("seed node record: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := provider.DestroyInstance(ctx, testVultrDestroyID); err != nil {
		t.Fatalf("DestroyInstance should treat 404 as success, got: %v", err)
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if _, ok := records[testVultrDestroyID]; ok {
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
	if err := provider.persistNodeRecord(testVultrDestroyID, nodeRecord{InstanceID: testVultrDestroyID, Label: "stale-node", Region: "lax"}); err != nil {
		t.Fatalf("seed node record: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := provider.DestroyInstance(ctx, testVultrDestroyID); err == nil {
		t.Fatalf("expected DestroyInstance to fail on a real API error")
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if _, ok := records[testVultrDestroyID]; !ok {
		t.Fatalf("local record must be kept when the destroy call genuinely fails")
	}
}

func TestDestroyInstanceReportsLocalRecordRemovalFailure(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("file permissions do not block root")
	}
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	newDestroyFakeServer(t, http.StatusNoContent)

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	if err := provider.persistNodeRecord(testVultrDestroyID, nodeRecord{InstanceID: testVultrDestroyID, Label: "stale-node", Region: "lax"}); err != nil {
		t.Fatalf("seed node record: %v", err)
	}
	nodesDir := filepath.Dir(provider.nodesPath)
	if err := os.Chmod(nodesDir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(nodesDir, 0o700) })

	err := provider.DestroyInstance(context.Background(), testVultrDestroyID)
	if err == nil || !strings.Contains(err.Error(), "local node record could not be removed") {
		t.Fatalf("DestroyInstance error = %v, want explicit local persistence failure", err)
	}
	if err := os.Chmod(nodesDir, 0o700); err != nil {
		t.Fatal(err)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := records[testVultrDestroyID]; !ok {
		t.Fatal("failed local removal should leave the record for a visible retry")
	}
}
