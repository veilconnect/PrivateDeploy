package vultr

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

func (p *Provider) loadNodeRecords() (map[string]nodeRecord, error) {
	nodesMu.Lock()
	defer nodesMu.Unlock()

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

	records := make(map[string]nodeRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, err
	}
	return records, nil
}

func (p *Provider) saveNodeRecords(records map[string]nodeRecord) error {
	nodesMu.Lock()
	defer nodesMu.Unlock()

	if err := os.MkdirAll(filepath.Dir(p.nodesPath), 0o750); err != nil {
		return err
	}

	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p.nodesPath, data, 0o600)
}

func parseTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339, value); err == nil {
		return t
	}
	return time.Time{}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func toCloudInstance(inst vultrInstance, record nodeRecord) cloud.Instance {
	created := parseTime(firstNonEmpty(inst.CreatedAt, record.CreatedAt))

	return cloud.Instance{
		ID:                 inst.ID,
		Provider:           "vultr",
		Label:              firstNonEmpty(inst.Label, record.Label),
		Status:             inst.Status,
		Region:             firstNonEmpty(inst.Region, record.Region),
		Plan:               record.Plan,
		OSID:               record.OSID,
		IPv4:               firstNonEmpty(inst.MainIP, record.IPv4),
		IPv6:               firstNonEmpty(inst.V6MainIP, record.IPv6),
		Port:               record.Port,
		Password:           record.Password,
		CreatedAt:          created,
		SSPort:             record.SSPort,
		SSPassword:         record.SSPassword,
		HysteriaPort:       record.HysteriaPort,
		HysteriaPassword:   record.HysteriaPassword,
		HysteriaServerName: record.HysteriaServerName,
		HysteriaInsecure:   record.HysteriaInsecure,
		VLESSPort:          record.VLESSPort,
		VLESSUUID:          record.VLESSUUID,
		VLESSPublicKey:     record.VLESSPublicKey,
		VLESSShortID:       record.VLESSShortID,
		VLESSServerName:    record.VLESSServerName,
		TrojanPort:         record.TrojanPort,
		TrojanPassword:     record.TrojanPassword,
		TrojanServerName:   record.TrojanServerName,
		TrojanInsecure:     record.TrojanInsecure,
	}
}

func clearNodeRecordCredentials(record *nodeRecord) bool {
	changed := false

	resetInt := func(target *int) {
		if *target != 0 {
			*target = 0
			changed = true
		}
	}
	resetString := func(target *string) {
		if strings.TrimSpace(*target) != "" {
			*target = ""
			changed = true
		}
	}
	resetBoolPtr := func(target **bool) {
		if *target != nil {
			*target = nil
			changed = true
		}
	}

	resetInt(&record.Port)
	resetString(&record.Password)
	resetInt(&record.SSPort)
	resetString(&record.SSPassword)
	resetInt(&record.HysteriaPort)
	resetString(&record.HysteriaPassword)
	resetString(&record.HysteriaServerName)
	resetBoolPtr(&record.HysteriaInsecure)
	resetInt(&record.VLESSPort)
	resetString(&record.VLESSUUID)
	resetString(&record.VLESSPublicKey)
	resetString(&record.VLESSShortID)
	resetString(&record.VLESSServerName)
	resetInt(&record.TrojanPort)
	resetString(&record.TrojanPassword)
	resetString(&record.TrojanServerName)
	resetBoolPtr(&record.TrojanInsecure)

	return changed
}

func vultrRecordMatchesInstanceAddress(record nodeRecord, inst vultrInstance) bool {
	recordIPv4 := strings.TrimSpace(record.IPv4)
	instanceIPv4 := strings.TrimSpace(inst.MainIP)
	if recordIPv4 != "" && instanceIPv4 != "" && recordIPv4 == instanceIPv4 {
		return true
	}

	recordIPv6 := strings.TrimSpace(record.IPv6)
	instanceIPv6 := strings.TrimSpace(inst.V6MainIP)
	return recordIPv6 != "" && instanceIPv6 != "" && strings.EqualFold(recordIPv6, instanceIPv6)
}

func vultrRecordMatchesLabelRegion(record nodeRecord, inst vultrInstance) bool {
	label := strings.TrimSpace(record.Label)
	region := strings.TrimSpace(record.Region)
	instanceLabel := strings.TrimSpace(inst.Label)
	instanceRegion := strings.TrimSpace(inst.Region)

	return label != "" &&
		region != "" &&
		instanceLabel != "" &&
		instanceRegion != "" &&
		strings.EqualFold(label, instanceLabel) &&
		strings.EqualFold(region, instanceRegion)
}

func findReplacementNodeRecord(
	inst vultrInstance,
	records map[string]nodeRecord,
	liveIDs map[string]struct{},
	claimed map[string]struct{},
) (string, nodeRecord, bool) {
	addressMatches := make([]string, 0, 1)
	labelRegionMatches := make([]string, 0, 1)

	for id, record := range records {
		if id == inst.ID {
			continue
		}
		if _, ok := liveIDs[id]; ok {
			continue
		}
		if _, ok := claimed[id]; ok {
			continue
		}
		if vultrRecordMatchesInstanceAddress(record, inst) {
			addressMatches = append(addressMatches, id)
			continue
		}
		if vultrRecordMatchesLabelRegion(record, inst) {
			labelRegionMatches = append(labelRegionMatches, id)
		}
	}

	selectCandidate := func(candidates []string) (string, nodeRecord, bool) {
		if len(candidates) != 1 {
			return "", nodeRecord{}, false
		}
		id := candidates[0]
		record, ok := records[id]
		return id, record, ok
	}

	if id, record, ok := selectCandidate(addressMatches); ok {
		return id, record, true
	}
	if id, record, ok := selectCandidate(labelRegionMatches); ok {
		return id, record, true
	}

	return "", nodeRecord{}, false
}

func recordsToInstances(records map[string]nodeRecord) []cloud.Instance {
	instances := make([]cloud.Instance, 0, len(records))
	for id, record := range records {
		_ = ensureManagedTLSDefaults(&record.InstanceRecord)
		inst := vultrInstance{
			ID:        id,
			Label:     firstNonEmpty(record.Label, id),
			Status:    "unknown",
			Region:    record.Region,
			MainIP:    record.IPv4,
			V6MainIP:  record.IPv6,
			CreatedAt: record.CreatedAt,
		}
		instance := toCloudInstance(inst, record)
		if instance.Label == "" {
			instance.Label = id
		}
		if instance.Region == "" && record.Region != "" {
			instance.Region = record.Region
		}
		instances = append(instances, instance)
	}

	sort.Slice(instances, func(i, j int) bool {
		if !instances[i].CreatedAt.IsZero() && !instances[j].CreatedAt.IsZero() {
			return instances[i].CreatedAt.Before(instances[j].CreatedAt)
		}
		return instances[i].ID < instances[j].ID
	})
	return instances
}

// validateNodeRecord checks if a node record has complete proxy configuration.
func validateNodeRecord(record nodeRecord) bool {
	// A valid record must have at least Shadowsocks configuration.
	if record.SSPort == 0 || record.SSPassword == "" {
		return false
	}
	// If Port is set (legacy field), it should match SSPort.
	if record.Port != 0 && record.Port != record.SSPort {
		return false
	}
	return true
}
