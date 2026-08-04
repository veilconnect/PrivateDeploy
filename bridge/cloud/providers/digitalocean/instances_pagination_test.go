package digitalocean

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestListInstancesTraversesAllPagesBeforePruning(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-key"})
	seedDigitalOceanPaginationRecords(t, provider, map[string]cloud.InstanceRecord{
		"cloud-do-101": {IPv4: "192.0.2.101", SSPort: 4101, SSPassword: "first-secret"},
		"cloud-do-202": {IPv4: "192.0.2.202", SSPort: 4202, SSPassword: "second-secret"},
	})

	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Query().Get("page") {
		case "2":
			_, _ = w.Write([]byte(`{"droplets":[{"id":202,"name":"second","status":"active","created_at":"2026-07-13T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"},"networks":{"v4":[{"ip_address":"192.0.2.202","type":"public"}],"v6":[]}}],"links":{"pages":{}}}`))
		default:
			_, _ = w.Write([]byte(`{"droplets":[{"id":101,"name":"first","status":"active","created_at":"2026-07-12T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"},"networks":{"v4":[{"ip_address":"192.0.2.101","type":"public"}],"v6":[]}}],"links":{"pages":{"next":"` + server.URL + `/droplets?per_page=200&page=2"}}}`))
		}
	}))
	t.Cleanup(server.Close)

	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })
	provider.client = server.Client()

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances: %v", err)
	}
	if len(instances) != 2 {
		t.Fatalf("expected both pages, got %d instances: %#v", len(instances), instances)
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if got := records["cloud-do-202"].SSPassword; got != "second-secret" {
		t.Fatalf("second-page record credential was lost: got %q", got)
	}
}

func TestListInstancesSecondPageFailureDoesNotPruneRecords(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-key"})
	seedDigitalOceanPaginationRecords(t, provider, map[string]cloud.InstanceRecord{
		"cloud-do-101": {IPv4: "192.0.2.101", SSPort: 4101, SSPassword: "first-secret"},
		"cloud-do-202": {IPv4: "192.0.2.202", SSPort: 4202, SSPassword: "second-secret"},
	})
	before, err := os.ReadFile(provider.nodesPath)
	if err != nil {
		t.Fatalf("read seeded records: %v", err)
	}

	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("page") == "2" {
			http.Error(w, "temporary failure", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"droplets":[{"id":101,"name":"first","status":"active","created_at":"2026-07-12T00:00:00Z","region":{"slug":"sgp1"},"size":{"slug":"s-1vcpu-1gb"},"networks":{"v4":[{"ip_address":"192.0.2.101","type":"public"}],"v6":[]}}],"links":{"pages":{"next":"` + server.URL + `/droplets?per_page=200&page=2"}}}`))
	}))
	t.Cleanup(server.Close)

	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })
	provider.client = server.Client()

	if _, err := provider.ListInstances(context.Background()); err == nil {
		t.Fatal("expected second-page failure to fail closed")
	}
	after, err := os.ReadFile(provider.nodesPath)
	if err != nil {
		t.Fatalf("read records after failure: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("records changed after partial pagination failure\nbefore: %s\nafter: %s", before, after)
	}
}

func seedDigitalOceanPaginationRecords(t *testing.T, provider *Provider, records map[string]cloud.InstanceRecord) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o750); err != nil {
		t.Fatalf("mkdir records directory: %v", err)
	}
	data, err := json.Marshal(records)
	if err != nil {
		t.Fatalf("marshal records: %v", err)
	}
	if err := os.WriteFile(provider.nodesPath, data, 0o600); err != nil {
		t.Fatalf("write records: %v", err)
	}
}
