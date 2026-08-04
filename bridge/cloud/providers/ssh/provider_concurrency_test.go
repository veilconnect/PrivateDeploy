package ssh

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestProviderConfigIsDeepCopiedAndConcurrentSafe(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)

	original := &cloud.ProviderConfig{
		Provider: "ssh",
		Extra: map[string]string{
			"host":     "initial.example",
			"username": "root",
		},
	}
	provider := New(original)
	original.Extra["host"] = "caller-mutated.example"
	if got := provider.configSnapshot().Extra["host"]; got != "initial.example" {
		t.Fatalf("New retained caller-owned Extra map: got %q", got)
	}

	if err := provider.SaveConfig(&cloud.ProviderConfig{
		Provider: "ssh",
		Extra:    map[string]string{"host": "saved.example"},
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	loaded, err := provider.LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	loaded.Extra["host"] = "return-value-mutated.example"
	if got := provider.configSnapshot().Extra["host"]; got != "saved.example" {
		t.Fatalf("LoadConfig returned provider-owned Extra map: got %q", got)
	}

	const workers = 12
	var wg sync.WaitGroup
	errs := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for iteration := 0; iteration < 20; iteration++ {
				if i%2 == 0 {
					errs[i] = provider.SaveConfig(&cloud.ProviderConfig{
						Provider: "ssh",
						Extra: map[string]string{
							"host": fmt.Sprintf("host-%d-%d.example", i, iteration),
						},
					})
				} else {
					var cfg *cloud.ProviderConfig
					cfg, errs[i] = provider.LoadConfig()
					if cfg != nil {
						cfg.Extra["test-only"] = "mutated"
					}
				}
				if errs[i] != nil {
					return
				}
			}
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("config worker %d: %v", i, err)
		}
	}
}

func TestMutateNodeRecordsConcurrentUpsertsPersistAll(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	provider := New(nil)

	const workers = 32
	var wg sync.WaitGroup
	errs := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprintf("node-%02d", i)
			errs[i] = provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
				records[id] = testNodeRecord(id, i)
				return true, nil
			})
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("upsert worker %d: %v", i, err)
		}
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if len(records) != workers {
		t.Fatalf("lost concurrent updates: want %d records, got %d", workers, len(records))
	}
	for i := 0; i < workers; i++ {
		id := fmt.Sprintf("node-%02d", i)
		if records[id].SSPort != 23000+i {
			t.Fatalf("record %s missing or corrupted: %+v", id, records[id])
		}
	}
}

func TestListAndFailedDestroyInstancesAreConcurrentSafeAndPreserveRecords(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	provider := New(nil) // no auth: destroy must fail closed and retain records

	const workers = 24
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		for i := 0; i < workers; i++ {
			id := fmt.Sprintf("node-%02d", i)
			records[id] = testNodeRecord(id, i)
		}
		return true, nil
	}); err != nil {
		t.Fatalf("seed records: %v", err)
	}

	ctx := context.Background()
	var wg sync.WaitGroup
	errs := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprintf("node-%02d", i)
			errs[i] = provider.DestroyInstance(ctx, id)
		}(i)
	}
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = provider.ListInstances(ctx)
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err == nil || !strings.Contains(err.Error(), "credentials unavailable") {
			t.Fatalf("destroy worker %d did not fail closed: %v", i, err)
		}
	}
	instances, err := provider.ListInstances(ctx)
	if err != nil {
		t.Fatalf("final ListInstances: %v", err)
	}
	if len(instances) != workers {
		t.Fatalf("failed destroys lost records: want %d, got %+v", workers, instances)
	}
}

func TestNodeRecordLoadFailureIsFailClosed(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	provider := New(nil)
	if err := os.MkdirAll(filepath.Dir(provider.nodesPath), 0o750); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	corrupt := []byte("{ definitely-not-valid-json")
	if err := os.WriteFile(provider.nodesPath, corrupt, 0o600); err != nil {
		t.Fatalf("write corrupt records: %v", err)
	}

	callbackCalled := false
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		callbackCalled = true
		records["replacement"] = testNodeRecord("replacement", 1)
		return true, nil
	}); err == nil {
		t.Fatal("expected corrupt records to reject mutation")
	}
	if callbackCalled {
		t.Fatal("mutation callback ran after records load failure")
	}
	if _, err := provider.ListInstances(context.Background()); err == nil {
		t.Fatal("ListInstances should fail closed on corrupt records")
	}
	if err := provider.DestroyInstance(context.Background(), "replacement"); err == nil {
		t.Fatal("DestroyInstance should fail closed on corrupt records")
	}
	got, err := os.ReadFile(provider.nodesPath)
	if err != nil {
		t.Fatalf("read records after failures: %v", err)
	}
	if !bytes.Equal(got, corrupt) {
		t.Fatalf("corrupt records were overwritten after load failure: %q", got)
	}
}

func TestNewInstanceIDIsUniqueUnderConcurrency(t *testing.T) {
	const workers = 512
	ids := make(chan string, workers)
	errs := make(chan error, workers)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, err := newInstanceID("2001:db8::1")
			if err != nil {
				errs <- err
				return
			}
			ids <- id
		}()
	}
	wg.Wait()
	close(ids)
	close(errs)
	for err := range errs {
		t.Fatalf("newInstanceID: %v", err)
	}
	seen := make(map[string]struct{}, workers)
	for id := range ids {
		if _, duplicate := seen[id]; duplicate {
			t.Fatalf("duplicate instance ID: %s", id)
		}
		seen[id] = struct{}{}
	}
	if len(seen) != workers {
		t.Fatalf("want %d IDs, got %d", workers, len(seen))
	}
}

func testNodeRecord(id string, index int) nodeRecord {
	return nodeRecord{
		InstanceID: id,
		Label:      "test-" + id,
		Host:       "203.0.113.10",
		InstanceRecord: cloud.InstanceRecord{
			IPv4:       "203.0.113.10",
			Port:       22,
			SSPort:     23000 + index,
			SSPassword: "test-password",
		},
	}
}

func TestCreateHostPrecedenceContract(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{
		Provider: "ssh",
		Extra:    map[string]string{"host": "config.example"},
	})

	tests := []struct {
		name string
		opts *cloud.CreateInstanceOptions
		want string
	}{
		{name: "saved config fallback", opts: &cloud.CreateInstanceOptions{}, want: "config.example"},
		{name: "top-level host overrides config", opts: &cloud.CreateInstanceOptions{Host: "top.example"}, want: "top.example"},
		{name: "extra host overrides top-level", opts: &cloud.CreateInstanceOptions{Host: "top.example", Extra: map[string]string{"host": "extra.example"}}, want: "extra.example"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			extra, err := provider.mergedCreateExtra(tt.opts)
			if err != nil {
				t.Fatalf("mergedCreateExtra: %v", err)
			}
			if got := extra["host"]; got != tt.want {
				t.Fatalf("host precedence: got %q, want %q", got, tt.want)
			}
		})
	}
}
