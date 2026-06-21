package digitalocean

import (
	"errors"
	"os"
	"path/filepath"

	"privatedeploy/bridge/cloud"
)

func (p *Provider) loadNodeRecords() (map[string]cloud.InstanceRecord, error) {
	digitaloceanNodesMu.Lock()
	defer digitaloceanNodesMu.Unlock()

	data, err := os.ReadFile(p.nodesPath)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]cloud.InstanceRecord{}, nil
	}
	if err != nil {
		return nil, err
	}

	if len(data) == 0 {
		return map[string]cloud.InstanceRecord{}, nil
	}

	records := map[string]cloud.InstanceRecord{}
	if err := cloud.DecodeRecords(data, &records); err != nil {
		return nil, err
	}

	return records, nil
}

func (p *Provider) saveNodeRecords(records map[string]cloud.InstanceRecord) error {
	digitaloceanNodesMu.Lock()
	defer digitaloceanNodesMu.Unlock()

	if err := os.MkdirAll(filepath.Dir(p.nodesPath), 0o750); err != nil {
		return err
	}

	data, err := cloud.EncodeRecords(records)
	if err != nil {
		return err
	}

	return os.WriteFile(p.nodesPath, data, 0o600)
}

func (p *Provider) deleteNodeRecord(instanceID string) error {
	records, err := p.loadNodeRecords()
	if err != nil {
		return err
	}

	if _, ok := records[instanceID]; !ok {
		return nil
	}

	delete(records, instanceID)
	return p.saveNodeRecords(records)
}
