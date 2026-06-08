package cloud

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestPrepareAndRestoreProviderConfigForSave(t *testing.T) {
	secretDir := t.TempDir()
	t.Setenv(secretStoreDirEnv, secretDir)

	configPath := filepath.Join(t.TempDir(), "vultr.json")
	config := &ProviderConfig{
		Provider:      "vultr",
		APIKey:        "top-secret",
		DefaultRegion: "sgp",
		Extra:         map[string]string{"plan": "vc2-1c-1gb"},
	}

	sanitized, err := PrepareProviderConfigForSave(configPath, config)
	if err != nil {
		t.Fatalf("prepare config: %v", err)
	}
	if sanitized.APIKey != "" {
		t.Fatalf("expected sanitized config to omit api key, got %q", sanitized.APIKey)
	}

	raw, err := json.Marshal(sanitized)
	if err != nil {
		t.Fatalf("marshal sanitized config: %v", err)
	}
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatalf("write config file: %v", err)
	}

	var loaded ProviderConfig
	if err := json.Unmarshal(raw, &loaded); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}

	migrated, err := RestoreProviderAPIKey(configPath, &loaded)
	if err != nil {
		t.Fatalf("restore api key: %v", err)
	}
	if migrated {
		t.Fatal("did not expect migration when config file was already sanitized")
	}
	if loaded.APIKey != "top-secret" {
		t.Fatalf("expected restored api key, got %q", loaded.APIKey)
	}
}

func TestRestoreProviderAPIKeyMigratesLegacyPlaintext(t *testing.T) {
	secretDir := t.TempDir()
	t.Setenv(secretStoreDirEnv, secretDir)

	configPath := filepath.Join(t.TempDir(), "digitalocean.json")
	config := &ProviderConfig{
		Provider: "digitalocean",
		APIKey:   "legacy-secret",
	}

	migrated, err := RestoreProviderAPIKey(configPath, config)
	if err != nil {
		t.Fatalf("restore api key: %v", err)
	}
	if !migrated {
		t.Fatal("expected legacy plaintext api key to require migration")
	}
	if config.APIKey != "legacy-secret" {
		t.Fatalf("expected api key to remain available in memory, got %q", config.APIKey)
	}

	loaded, err := loadProviderAPIKey(configPath, config.Provider)
	if err != nil {
		t.Fatalf("load persisted secret: %v", err)
	}
	if loaded != "legacy-secret" {
		t.Fatalf("expected persisted secret, got %q", loaded)
	}
}
