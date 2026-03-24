package vultr

import (
	"context"
	"encoding/json"
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
				IPv4:       "144.202.124.223",
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
	if instances[0].IPv4 != "144.202.124.223" {
		t.Fatalf("unexpected ipv4: %q", instances[0].IPv4)
	}
}
