package vultr

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"privatedeploy/bridge/cloud"
)

// TestGetAccountStatusAfterRestartLoadsAPIKeyFromDisk covers the registry
// restart shape: New(nil) must restore a previously saved key before the
// account probe, without a preceding LoadConfig or SaveConfig call.
func TestGetAccountStatusAfterRestartLoadsAPIKeyFromDisk(t *testing.T) {
	const apiKey = "vultr-restart-key"

	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	seed := New(nil)
	if err := seed.SaveConfig(&cloud.ProviderConfig{Provider: "vultr", APIKey: apiKey}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	rawConfig, err := os.ReadFile(seed.configPath)
	if err != nil {
		t.Fatalf("read saved config: %v", err)
	}
	if strings.Contains(string(rawConfig), apiKey) {
		t.Fatalf("on-disk config must not contain the plaintext API key: %s", rawConfig)
	}

	gotAuth := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/firewalls" {
			http.NotFound(w, r)
			return
		}
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"firewall_groups":[]}`))
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

	provider := New(nil)
	status, err := provider.GetAccountStatus(context.Background())
	if err != nil {
		t.Fatalf("GetAccountStatus: %v", err)
	}
	if status == nil || status.State != "active" || !status.CanDeploy {
		t.Fatalf("unexpected account status: %#v", status)
	}
	if gotAuth != "Bearer "+apiKey {
		t.Fatalf("Authorization = %q, want %q", gotAuth, "Bearer "+apiKey)
	}
}
