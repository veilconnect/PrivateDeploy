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

func TestListInstancesFallsBackToLocalNodeRecordsWithoutAPIKey(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	provider := New(nil)

	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o755); err != nil {
		t.Fatalf("mkdir nodes dir: %v", err)
	}

	records := map[string]nodeRecord{
		"inst-1": {
			InstanceID: "inst-1",
			Label:      "vultr",
			Region:     "lax",
			InstanceRecord: cloud.InstanceRecord{
				IPv4:       "198.51.100.10",
				CreatedAt:  "2026-03-24T10:20:59Z",
				SSPort:     23951,
				SSPassword: "secret",
			},
		},
	}
	payload, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		t.Fatalf("marshal records: %v", err)
	}
	if err := os.WriteFile(provider.nodesPath, payload, 0o600); err != nil {
		t.Fatalf("write nodes file: %v", err)
	}

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances error: %v", err)
	}
	if len(instances) != 1 {
		t.Fatalf("expected 1 instance, got %d", len(instances))
	}
	if instances[0].ID != "inst-1" {
		t.Fatalf("unexpected instance id: %q", instances[0].ID)
	}
	if instances[0].Label != "vultr" {
		t.Fatalf("unexpected label: %q", instances[0].Label)
	}
	if instances[0].IPv4 != "198.51.100.10" {
		t.Fatalf("unexpected ipv4: %q", instances[0].IPv4)
	}
}

func TestListInstancesMigratesReplacedRecordByIPAndRecoversUserData(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	provider := New(&cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "test-key",
	})

	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o755); err != nil {
		t.Fatalf("mkdir nodes dir: %v", err)
	}

	records := map[string]nodeRecord{
		"inst-old": {
			InstanceID: "inst-old",
			Label:      "sgp-node",
			Region:     "sgp",
			InstanceRecord: cloud.InstanceRecord{
				IPv4:       "192.0.2.10",
				CreatedAt:  "2026-03-24T10:20:59Z",
				SSPort:     43379,
				SSPassword: "old-secret",
				VLESSPort:  43381,
				VLESSUUID:  "old-vless",
				TrojanPort: 43382,
			},
		},
	}
	payload, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		t.Fatalf("marshal records: %v", err)
	}
	if err := os.WriteFile(provider.nodesPath, payload, 0o600); err != nil {
		t.Fatalf("write nodes file: %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/instances":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"instances":[{"id":"inst-new","label":"sgp-node","status":"active","region":"sgp","main_ip":"192.0.2.10","created_at":"2026-04-03T10:00:00Z"}]}`))
		case "/instances/inst-new/user-data":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"user_data":"IyEvYmluL2Jhc2gKc3Mtc2VydmVyIC1zIDAuMC4wLjAgLXAgNDQzNDMgLWsgIm5ldy1zcy1wYXNzIiAtbSBhZXMtMjU2LWdjbQ=="}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	defer func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	}()

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances error: %v", err)
	}
	if len(instances) != 1 {
		t.Fatalf("expected 1 instance, got %d", len(instances))
	}
	instance := instances[0]
	if instance.ID != "inst-new" {
		t.Fatalf("unexpected instance id: %q", instance.ID)
	}
	if instance.ReplacedInstanceID != "inst-old" {
		t.Fatalf("expected replacement to point to inst-old, got %q", instance.ReplacedInstanceID)
	}
	if instance.SSPort != 44343 {
		t.Fatalf("expected recovered ssPort 44343, got %d", instance.SSPort)
	}
	if instance.SSPassword != "new-ss-pass" {
		t.Fatalf("expected recovered ss password, got %q", instance.SSPassword)
	}

	savedRecords, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords error: %v", err)
	}
	if _, ok := savedRecords["inst-old"]; ok {
		t.Fatalf("expected stale inst-old record to be removed")
	}
	if saved, ok := savedRecords["inst-new"]; !ok {
		t.Fatalf("expected inst-new record to be persisted")
	} else if saved.SSPort != 44343 {
		t.Fatalf("expected persisted ssPort 44343, got %d", saved.SSPort)
	}
}

// TestListInstancesSelfHealsBlankPlanFromLiveAPI guards against a real bug:
// a node record whose Plan was ever lost (e.g. by a build-fresh-record
// fallback racing a concurrent refresh) could never repair/redeploy again —
// CreateInstanceOptions.Plan came only from the locally persisted record,
// with no live source of truth to recover from. Vultr's own instance payload
// carries the plan ID, so ListInstances must treat it like Label/Region and
// self-heal a blank local Plan on the very next refresh.
func TestListInstancesSelfHealsBlankPlanFromLiveAPI(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	provider := New(&cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "test-key",
	})

	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o755); err != nil {
		t.Fatalf("mkdir nodes dir: %v", err)
	}

	records := map[string]nodeRecord{
		"inst-blank-plan": {
			InstanceID: "inst-blank-plan",
			Label:      "lax-node",
			Region:     "lax",
			InstanceRecord: cloud.InstanceRecord{
				IPv4:       "203.0.113.20",
				CreatedAt:  "2026-08-04T10:00:00Z",
				SSPort:     38367,
				SSPassword: "secret",
				// Plan intentionally blank, simulating a previously-lost value.
			},
		},
	}
	payload, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		t.Fatalf("marshal records: %v", err)
	}
	if err := os.WriteFile(provider.nodesPath, payload, 0o600); err != nil {
		t.Fatalf("write nodes file: %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/instances" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"instances":[{"id":"inst-blank-plan","label":"lax-node","status":"active","region":"lax","plan":"vc2-1c-1gb","main_ip":"203.0.113.20","created_at":"2026-08-04T10:00:00Z"}]}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	defer func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	}()

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances error: %v", err)
	}
	if len(instances) != 1 {
		t.Fatalf("expected 1 instance, got %d", len(instances))
	}
	if instances[0].Plan != "vc2-1c-1gb" {
		t.Fatalf("expected self-healed plan vc2-1c-1gb, got %q", instances[0].Plan)
	}

	savedRecords, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords error: %v", err)
	}
	if saved, ok := savedRecords["inst-blank-plan"]; !ok {
		t.Fatalf("expected record to still be persisted")
	} else if saved.Plan != "vc2-1c-1gb" {
		t.Fatalf("expected persisted plan to be self-healed to vc2-1c-1gb, got %q", saved.Plan)
	}
}
