package ssh

import (
	"encoding/json"
	"os"
	"path/filepath"
	"privatedeploy/bridge/cloud"
	"testing"
)

func TestSaveConfigRedactsSensitiveSSHExtra(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	provider := New(nil)
	cfg := &cloud.ProviderConfig{
		Provider: "ssh",
		Extra: map[string]string{
			"host":       "203.0.113.10",
			"username":   "root",
			"authMethod": "password",
			"password":   "secret",
			"privateKey": "PRIVATE KEY",
		},
	}

	if err := provider.SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(basePath, configFileRelPath))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}

	var persisted cloud.ProviderConfig
	if err := json.Unmarshal(data, &persisted); err != nil {
		t.Fatalf("decode config: %v", err)
	}

	if _, exists := persisted.Extra["password"]; exists {
		t.Fatalf("expected password to be redacted, got %#v", persisted.Extra["password"])
	}
	if _, exists := persisted.Extra["privateKey"]; exists {
		t.Fatalf("expected privateKey to be redacted, got %#v", persisted.Extra["privateKey"])
	}
	if persisted.Extra["host"] != "203.0.113.10" {
		t.Fatalf("expected host to persist, got %#v", persisted.Extra["host"])
	}
}

func TestLoadConfigMigratesLegacySensitiveSSHExtra(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	configPath := filepath.Join(basePath, configFileRelPath)
	if err := os.MkdirAll(filepath.Dir(configPath), 0o750); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}

	legacy := cloud.ProviderConfig{
		Provider: "ssh",
		Extra: map[string]string{
			"host":       "203.0.113.10",
			"authMethod": "password",
			"password":   "secret",
		},
	}
	payload, err := json.Marshal(legacy)
	if err != nil {
		t.Fatalf("marshal legacy config: %v", err)
	}
	if err := os.WriteFile(configPath, payload, 0o600); err != nil {
		t.Fatalf("write legacy config: %v", err)
	}

	provider := New(nil)
	cfg, err := provider.LoadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if _, exists := cfg.Extra["password"]; exists {
		t.Fatalf("expected password to be removed from loaded config, got %#v", cfg.Extra["password"])
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("read rewritten config: %v", err)
	}
	if string(data) == string(payload) {
		t.Fatal("expected legacy config to be rewritten without secrets")
	}
}
