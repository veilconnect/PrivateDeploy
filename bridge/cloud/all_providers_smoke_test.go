package cloud_test

import (
	"slices"
	"testing"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/providers/digitalocean"
	sshprovider "privatedeploy/bridge/cloud/providers/ssh"
	"privatedeploy/bridge/cloud/providers/vultr"
)

func TestAllProvidersOfflineSmoke(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", t.TempDir())

	reg := cloud.NewRegistry()
	reg.Register("vultr", vultr.New(nil))
	reg.Register("digitalocean", digitalocean.New(nil))
	reg.Register("ssh", sshprovider.New(nil))

	names := reg.List()
	slices.Sort(names)
	expected := []string{
		"digitalocean",
		"ssh",
		"vultr",
	}
	if !slices.Equal(names, expected) {
		t.Fatalf("provider registry mismatch: got=%v want=%v", names, expected)
	}
	for _, name := range names {
		provider, err := reg.Get(name)
		if err != nil {
			t.Fatalf("failed to get provider %s: %v", name, err)
		}

		cfg := &cloud.ProviderConfig{Provider: name, Extra: map[string]string{}}
		if name != "ssh" {
			cfg.APIKey = "test-key"
		}

		if err := provider.ValidateConfig(cfg); err != nil {
			t.Fatalf("validate config failed for %s: %v", name, err)
		}

		if err := provider.SaveConfig(cfg); err != nil {
			t.Fatalf("save config failed for %s: %v", name, err)
		}

		loaded, err := provider.LoadConfig()
		if err != nil {
			t.Fatalf("load config failed for %s: %v", name, err)
		}
		if loaded.Provider != name {
			t.Fatalf("loaded provider mismatch for %s: got=%s", name, loaded.Provider)
		}
		if name != "ssh" && loaded.APIKey != "test-key" {
			t.Fatalf("loaded api key mismatch for %s: got=%q", name, loaded.APIKey)
		}
	}
}
