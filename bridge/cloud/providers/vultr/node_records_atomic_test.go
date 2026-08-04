package vultr

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"privatedeploy/bridge/cloud"
)

// TestMutateNodeRecordsConcurrentUpsertsPersistAll drives N concurrent
// atomic upserts against different instance IDs. With the old split
// load(lock)→modify→save(lock) pattern the later writer overwrote the earlier
// one; with mutateNodeRecords holding the mutex for the whole cycle every
// record must survive to disk. Run with -race to also catch unlocked access.
func TestMutateNodeRecordsConcurrentUpsertsPersistAll(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))

	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})

	const workers = 8
	var wg sync.WaitGroup
	errs := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprintf("inst-%d", i)
			errs[i] = provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
				records[id] = nodeRecord{
					InstanceID: id,
					Label:      "node-" + id,
					Region:     "nrt",
					InstanceRecord: cloud.InstanceRecord{
						SSPort:     23650 + i,
						SSPassword: "pw-" + id,
					},
				}
				return true, nil
			})
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("mutateNodeRecords worker %d: %v", i, err)
		}
	}

	if _, err := os.Stat(provider.nodesPath); err != nil {
		t.Fatalf("nodes file should exist on disk: %v", err)
	}

	// Read back through a fresh provider so the assertion goes through the
	// on-disk state, not any in-memory leftovers.
	records, err := New(nil).loadNodeRecords()
	if err != nil {
		t.Fatalf("loadNodeRecords: %v", err)
	}
	if len(records) != workers {
		t.Fatalf("expected %d records on disk, got %d: %v", workers, len(records), records)
	}
	for i := 0; i < workers; i++ {
		id := fmt.Sprintf("inst-%d", i)
		record, ok := records[id]
		if !ok {
			t.Fatalf("record %s missing from disk (lost update)", id)
		}
		if record.SSPort != 23650+i || record.SSPassword != "pw-"+id {
			t.Fatalf("record %s corrupted: %+v", id, record)
		}
	}
}
