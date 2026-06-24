package cdn

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"privatedeploy/bridge/cloud"
)

// Use a file-backed secret store so the test never touches the real OS keyring.
func useFileSecretStore(t *testing.T) {
	t.Helper()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", t.TempDir())
}

func readConfigToken(t *testing.T, basePath string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(basePath, configFileRel))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	var cfg persistedConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}
	return cfg.Token
}

func TestCDNTokenNeverPersistedInPlaintext(t *testing.T) {
	useFileSecretStore(t)
	base := t.TempDir()

	m := NewManager(base)
	m.cfg.Token = "cf-secret-token-123"
	m.cfg.AccountID = "acct-1"
	if err := m.saveConfigLocked(); err != nil {
		t.Fatalf("saveConfigLocked: %v", err)
	}

	// config.json must NOT contain the token.
	if tok := readConfigToken(t, base); tok != "" {
		t.Fatalf("token leaked into config.json: %q", tok)
	}
	raw, _ := os.ReadFile(filepath.Join(base, configFileRel))
	if strings.Contains(string(raw), "cf-secret-token-123") {
		t.Fatalf("config.json contains the cleartext token:\n%s", raw)
	}

	// The secret store must hold it.
	got, err := cloud.LoadSecret(m.configPath(), cdnSecretScope)
	if err != nil || got != "cf-secret-token-123" {
		t.Fatalf("secret store token = %q, err = %v", got, err)
	}

	// A fresh Manager must restore the token from the secret store.
	m2 := NewManager(base)
	if m2.cfg.Token != "cf-secret-token-123" {
		t.Fatalf("restored token = %q, want it loaded from secret store", m2.cfg.Token)
	}
}

func TestCDNLegacyPlaintextTokenIsMigrated(t *testing.T) {
	useFileSecretStore(t)
	base := t.TempDir()
	dir := filepath.Join(base, "data", "cdn")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	// Simulate a legacy build that wrote the token straight into config.json.
	legacy := persistedConfig{Token: "legacy-token-xyz", AccountID: "acct-legacy"}
	data, _ := json.MarshalIndent(legacy, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}

	// Constructing the manager triggers load(), which migrates the token.
	m := NewManager(base)
	if m.cfg.Token != "legacy-token-xyz" {
		t.Fatalf("token not kept in memory after migration: %q", m.cfg.Token)
	}
	if tok := readConfigToken(t, base); tok != "" {
		t.Fatalf("legacy token still in config.json after migration: %q", tok)
	}
	got, err := cloud.LoadSecret(m.configPath(), cdnSecretScope)
	if err != nil || got != "legacy-token-xyz" {
		t.Fatalf("legacy token not migrated into secret store: got %q err %v", got, err)
	}
}
