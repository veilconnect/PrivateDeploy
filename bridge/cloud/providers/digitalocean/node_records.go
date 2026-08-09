package digitalocean

import (
	"errors"
	"os"
	"path/filepath"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/persistence"
)

// loadNodeRecordsLocked reads the records file. Callers must hold
// digitaloceanNodesMu.
func (p *Provider) loadNodeRecordsLocked() (map[string]nodeRecord, error) {
	data, err := os.ReadFile(p.nodesPath)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]nodeRecord{}, nil
	}
	if err != nil {
		return nil, err
	}

	if len(data) == 0 {
		return map[string]nodeRecord{}, nil
	}

	records := map[string]nodeRecord{}
	if err := cloud.DecodeRecords(data, &records); err != nil {
		return nil, err
	}

	return records, nil
}

// saveNodeRecordsLocked writes the records file. Callers must hold
// digitaloceanNodesMu.
func (p *Provider) saveNodeRecordsLocked(records map[string]nodeRecord) error {
	if err := os.MkdirAll(filepath.Dir(p.nodesPath), 0o750); err != nil {
		return err
	}

	data, err := cloud.EncodeRecords(records)
	if err != nil {
		return err
	}

	return persistence.WritePrivateFileAtomic(p.nodesPath, data)
}

// loadNodeRecords returns a snapshot of the node records. It must only be used
// for read-only access: any load→modify→save sequence built on top of it can
// lose updates to a concurrent writer. Mutations must go through
// mutateNodeRecords instead.
func (p *Provider) loadNodeRecords() (map[string]nodeRecord, error) {
	digitaloceanNodesMu.Lock()
	defer digitaloceanNodesMu.Unlock()
	return p.loadNodeRecordsLocked()
}

// mutateNodeRecords runs an atomic read-modify-write cycle on the records
// file, holding digitaloceanNodesMu for the whole load→mutate→save sequence so
// concurrent mutations can never overwrite each other's writes. The callback
// may modify the records map in place and returns whether the result should be
// persisted; returning save=false skips the write for no-op flows. The
// callback must not call back into loadNodeRecords / mutateNodeRecords (the
// mutex is not reentrant).
func (p *Provider) mutateNodeRecords(mutate func(records map[string]nodeRecord) (save bool, err error)) error {
	digitaloceanNodesMu.Lock()
	defer digitaloceanNodesMu.Unlock()

	records, err := p.loadNodeRecordsLocked()
	if err != nil {
		return err
	}

	save, err := mutate(records)
	if err != nil {
		return err
	}
	if !save {
		return nil
	}

	return p.saveNodeRecordsLocked(records)
}

func (p *Provider) deleteNodeRecord(instanceID string) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if _, ok := records[instanceID]; !ok {
			return false, nil
		}
		delete(records, instanceID)
		return true, nil
	})
}

func (p *Provider) markFirewallCleanupPending(instanceID string) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok || record.FirewallCleanupPending {
			return false, nil
		}
		record.FirewallCleanupPending = true
		records[instanceID] = record
		return true, nil
	})
}
