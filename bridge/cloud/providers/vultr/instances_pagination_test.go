package vultr

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

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	seedVultrPaginationRecords(t, provider, map[string]nodeRecord{
		"inst-101": paginationNodeRecord("inst-101", "192.0.2.101", 4101, "first-secret"),
		"inst-202": paginationNodeRecord("inst-202", "192.0.2.202", 4202, "second-secret"),
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Query().Get("cursor") == "page/two==" {
			_, _ = w.Write([]byte(`{"instances":[{"id":"inst-202","label":"second","status":"active","region":"sgp","main_ip":"192.0.2.202","created_at":"2026-07-13T00:00:00Z"}],"meta":{"links":{"next":""}}}`))
			return
		}
		_, _ = w.Write([]byte(`{"instances":[{"id":"inst-101","label":"first","status":"active","region":"sgp","main_ip":"192.0.2.101","created_at":"2026-07-12T00:00:00Z"}],"meta":{"links":{"next":"page/two=="}}}`))
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
	if got := records["inst-202"].SSPassword; got != "second-secret" {
		t.Fatalf("second-page record credential was lost: got %q", got)
	}
}

func TestListInstancesSecondPageFailureDoesNotPruneRecords(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	seedVultrPaginationRecords(t, provider, map[string]nodeRecord{
		"inst-101": paginationNodeRecord("inst-101", "192.0.2.101", 4101, "first-secret"),
		"inst-202": paginationNodeRecord("inst-202", "192.0.2.202", 4202, "second-secret"),
	})
	before, err := os.ReadFile(provider.nodesPath)
	if err != nil {
		t.Fatalf("read seeded records: %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("cursor") == "page/two==" {
			http.Error(w, "temporary failure", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"instances":[{"id":"inst-101","label":"first","status":"active","region":"sgp","main_ip":"192.0.2.101","created_at":"2026-07-12T00:00:00Z"}],"meta":{"links":{"next":"page/two=="}}}`))
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

func paginationNodeRecord(id, ip string, port int, password string) nodeRecord {
	return nodeRecord{
		InstanceID: id,
		Label:      id,
		Region:     "sgp",
		InstanceRecord: cloud.InstanceRecord{
			IPv4:       ip,
			SSPort:     port,
			SSPassword: password,
		},
	}
}

func seedVultrPaginationRecords(t *testing.T, provider *Provider, records map[string]nodeRecord) {
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
