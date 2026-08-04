package vultr

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestConcurrentConfigLoadSaveIsRaceFree(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	p := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "initial-key"})
	if err := p.SaveConfig(&cloud.ProviderConfig{Provider: "vultr", APIKey: "initial-key"}); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(3)
		go func(i int) {
			defer wg.Done()
			_ = p.SaveConfig(&cloud.ProviderConfig{
				Provider: "vultr",
				APIKey:   fmt.Sprintf("key-%d", i),
				Extra:    map[string]string{"writer": fmt.Sprint(i)},
			})
		}(i)
		go func() {
			defer wg.Done()
			_, _ = p.LoadConfig()
		}()
		go func() {
			defer wg.Done()
			_, _ = p.ensureConfig()
		}()
	}
	wg.Wait()

	if _, err := p.ensureConfig(); err != nil {
		t.Fatalf("final config unavailable: %v", err)
	}
}

func TestConfigCopiesDoNotAliasCallerState(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	input := &cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "saved-key",
		Extra:    map[string]string{"profile": "saved"},
	}
	p := New(nil)
	if err := p.SaveConfig(input); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	input.APIKey = "caller-mutated-key"
	input.Extra["profile"] = "caller-mutated"

	got, err := p.ensureConfig()
	if err != nil {
		t.Fatalf("ensureConfig: %v", err)
	}
	if got.APIKey != "saved-key" || got.Extra["profile"] != "saved" {
		t.Fatalf("provider retained caller-owned config: %#v", got)
	}

	got.APIKey = "returned-copy-mutated-key"
	got.Extra["profile"] = "returned-copy-mutated"
	gotAgain, err := p.ensureConfig()
	if err != nil {
		t.Fatalf("second ensureConfig: %v", err)
	}
	if gotAgain.APIKey != "saved-key" || gotAgain.Extra["profile"] != "saved" {
		t.Fatalf("ensureConfig returned provider-owned state: %#v", gotAgain)
	}
}
