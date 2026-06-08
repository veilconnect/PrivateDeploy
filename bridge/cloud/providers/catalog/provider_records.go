package catalog

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"privatedeploy/bridge/cloud"
)

// nodeRecord stores node metadata for providers that support lifecycle management.
type nodeRecord struct {
	cloud.InstanceRecord
	Label  string `json:"label"`
	Region string `json:"region"`
}

func (p *Provider) loadNodeRecords() (map[string]cloud.InstanceRecord, error) {
	catalogNodesMu.Lock()
	defer catalogNodesMu.Unlock()

	data, err := os.ReadFile(p.nodesPath)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]cloud.InstanceRecord{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read node records: %w", err)
	}
	if len(data) == 0 {
		return map[string]cloud.InstanceRecord{}, nil
	}

	var records map[string]cloud.InstanceRecord
	if err := json.Unmarshal(data, &records); err == nil {
		if records == nil {
			return map[string]cloud.InstanceRecord{}, nil
		}
		return records, nil
	}

	var old map[string]nodeRecord
	if err := json.Unmarshal(data, &old); err != nil {
		return nil, fmt.Errorf("failed to parse node records: %w", err)
	}
	converted := make(map[string]cloud.InstanceRecord, len(old))
	for id, rec := range old {
		converted[id] = rec.InstanceRecord
	}
	return converted, nil
}

func (p *Provider) saveNodeRecords(records map[string]cloud.InstanceRecord) error {
	catalogNodesMu.Lock()
	defer catalogNodesMu.Unlock()

	if records == nil {
		records = map[string]cloud.InstanceRecord{}
	}
	if err := os.MkdirAll(filepath.Dir(p.nodesPath), 0o755); err != nil {
		return fmt.Errorf("failed to create nodes directory: %w", err)
	}
	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal node records: %w", err)
	}
	if err := os.WriteFile(p.nodesPath, data, 0o600); err != nil {
		return fmt.Errorf("failed to write node records: %w", err)
	}
	return nil
}

func (p *Provider) deleteNodeRecord(instanceID string) error {
	records, err := p.loadNodeRecords()
	if err != nil {
		return err
	}
	delete(records, instanceID)
	return p.saveNodeRecords(records)
}
