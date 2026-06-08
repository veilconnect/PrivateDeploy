package digitalocean

import (
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestNew_NilConfig(t *testing.T) {
	p := New(nil)
	if p == nil {
		t.Fatal("New(nil) should return non-nil provider")
	}
	if p.config.Provider != "digitalocean" {
		t.Errorf("expected provider 'digitalocean', got %q", p.config.Provider)
	}
}

func TestNew_WithConfig(t *testing.T) {
	cfg := &cloud.ProviderConfig{
		Provider: "digitalocean",
		APIKey:   "test-key",
	}
	p := New(cfg)
	if p.config.APIKey != "test-key" {
		t.Errorf("expected APIKey 'test-key', got %q", p.config.APIKey)
	}
}

func TestProvider_Name(t *testing.T) {
	p := New(nil)
	if p.Name() != "digitalocean" {
		t.Errorf("expected 'digitalocean', got %q", p.Name())
	}
}

func TestProvider_DisplayName(t *testing.T) {
	p := New(nil)
	name := p.DisplayName()
	if name == "" {
		t.Error("DisplayName should not be empty")
	}
}

func TestProvider_ValidateConfig_MissingAPIKey(t *testing.T) {
	p := New(&cloud.ProviderConfig{Provider: "digitalocean"})
	err := p.ValidateConfig(p.config)
	if err == nil {
		t.Error("expected error when API key is missing")
	}
}

func TestProvider_ValidateConfig_Valid(t *testing.T) {
	p := New(&cloud.ProviderConfig{
		Provider: "digitalocean",
		APIKey:   "dop_v1_test123",
	})
	err := p.ValidateConfig(p.config)
	if err != nil {
		t.Errorf("unexpected error for valid config: %v", err)
	}
}

func TestProvider_ClientNotNil(t *testing.T) {
	p := New(nil)
	if p.client == nil {
		t.Error("HTTP client should not be nil")
	}
	if p.client.Timeout == 0 {
		t.Error("HTTP client should have a timeout")
	}
}

func TestProvider_PathsSet(t *testing.T) {
	p := New(nil)
	if p.configPath == "" {
		t.Error("configPath should not be empty")
	}
	if p.nodesPath == "" {
		t.Error("nodesPath should not be empty")
	}
}
