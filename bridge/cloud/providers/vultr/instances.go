package vultr

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

// instanceCredentials holds generated credentials for a deployment.
type instanceCredentials struct {
	ssPassword        string
	hysteriaPassword  string
	trojanPassword    string
	vlessUUID         string
	realityPrivateKey string
	realityPublicKey  string
	realityShortID    string
	ports             deploy.PortAssignment
}

// ListInstances returns all Vultr instances.
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	records, recordsErr := p.loadNodeRecords()
	if _, err := p.ensureConfig(); err != nil {
		if recordsErr == nil && len(records) > 0 {
			return recordsToInstances(records), nil
		}
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/instances", nil)
	if err != nil {
		if recordsErr != nil || len(records) == 0 {
			return nil, err
		}
		return recordsToInstances(records), nil
	}

	var payload struct {
		Instances []vultrInstance `json:"instances"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		if recordsErr != nil || len(records) == 0 {
			return nil, err
		}
		return recordsToInstances(records), nil
	}

	if recordsErr != nil {
		return nil, recordsErr
	}

	dirty := false
	liveIDs := make(map[string]struct{}, len(payload.Instances))
	for _, inst := range payload.Instances {
		liveIDs[inst.ID] = struct{}{}
	}
	claimedReplacements := make(map[string]struct{})
	seen := make(map[string]struct{}, len(payload.Instances))
	instances := make([]cloud.Instance, 0, len(payload.Instances))

	for _, inst := range payload.Instances {
		record, ok := records[inst.ID]
		replacedFrom := ""
		replacementDetected := false
		if !ok {
			if oldID, migrated, found := findReplacementNodeRecord(inst, records, liveIDs, claimedReplacements); found {
				record = migrated
				replacedFrom = oldID
				replacementDetected = true
				claimedReplacements[oldID] = struct{}{}
				delete(records, oldID)
				dirty = true
			} else {
				record = nodeRecord{
					InstanceID: inst.ID,
					Label:      inst.Label,
					Region:     inst.Region,
					InstanceRecord: cloud.InstanceRecord{
						CreatedAt: inst.CreatedAt,
					},
				}
				dirty = true
			}
		}

		if replacementDetected && clearNodeRecordCredentials(&record) {
			dirty = true
		}

		if replacementDetected || shouldRecoverNodeRecord(record) {
			if recovered, ok := p.recoverNodeRecordForInstance(ctx, inst, record); ok {
				record = recovered
				dirty = true
			}
		}

		if inst.MainIP != "" && record.IPv4 != inst.MainIP {
			record.IPv4 = inst.MainIP
			dirty = true
		}
		if inst.V6MainIP != "" && record.IPv6 != inst.V6MainIP {
			record.IPv6 = inst.V6MainIP
			dirty = true
		}
		if record.CreatedAt == "" && inst.CreatedAt != "" {
			record.CreatedAt = inst.CreatedAt
			dirty = true
		}
		if record.Port == 0 && record.SSPort != 0 {
			record.Port = record.SSPort
			dirty = true
		}
		if inst.Label != "" && record.Label != inst.Label {
			record.Label = inst.Label
			dirty = true
		}
		if inst.Region != "" && record.Region != inst.Region {
			record.Region = inst.Region
			dirty = true
		}
		if record.InstanceID == "" {
			record.InstanceID = inst.ID
			dirty = true
		}
		if ensureManagedTLSDefaults(&record.InstanceRecord) {
			dirty = true
		}

		records[inst.ID] = record
		seen[inst.ID] = struct{}{}
		instance := toCloudInstance(inst, record)
		if replacedFrom != "" {
			instance.ReplacedInstanceID = replacedFrom
		}
		instances = append(instances, instance)
	}

	if len(records) > len(seen) {
		for id := range records {
			if _, ok := seen[id]; !ok {
				delete(records, id)
				dirty = true
			}
		}
	}

	if dirty {
		_ = p.saveNodeRecords(records)
	}

	sort.Slice(instances, func(i, j int) bool {
		a := instances[i].CreatedAt
		b := instances[j].CreatedAt
		if !a.IsZero() && !b.IsZero() {
			return a.Before(b)
		}
		return instances[i].ID < instances[j].ID
	})

	return instances, nil
}

// CreateInstance creates a new Vultr instance.
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}
	if strings.TrimSpace(opts.Label) == "" || strings.TrimSpace(opts.Region) == "" || strings.TrimSpace(opts.Plan) == "" {
		return nil, fmt.Errorf("label, region and plan are required")
	}

	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}

	extra := mergeExtra(cfg.Extra, opts.Extra)
	tuning := deploy.ResolveDeploymentTuning(extra)

	planRAM, err := p.getPlanRAM(ctx, opts.Plan)
	if err != nil {
		planRAM = 1024
	}

	osIDs, err := p.preferredOSIDs(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to determine vultr os ids: %w", err)
	}
	if len(osIDs) == 0 {
		return nil, fmt.Errorf("failed to determine vultr os ids: no compatible images found")
	}

	creds, userData, err := p.generateDeploymentPayload(planRAM, tuning)
	if err != nil {
		return nil, err
	}

	payload, selectedOSID, err := p.createVultrInstance(ctx, opts, osIDs, userData)
	if err != nil {
		return nil, err
	}

	instanceID := payload.Instance.ID

	record := p.buildNodeRecord(instanceID, opts, selectedOSID, planRAM, creds, tuning)
	if err := p.persistNodeRecord(instanceID, record); err != nil {
		return nil, err
	}

	instance, err := p.waitForInstance(ctx, instanceID, 15*time.Minute)
	if err == nil {
		record = p.updateRecordFromInstance(instanceID, instance, record)
		p.configureInstanceFirewall(ctx, instanceID, creds.ports, opts.Label)
		p.waitForServiceReady(ctx, instance.MainIP, creds.ports, planRAM, extra)
	} else {
		instance = payload.Instance
	}

	cloudInst := toCloudInstance(instance, record)
	cloudInst.Region = payload.Instance.Region
	cloudInst.Status = payload.Instance.Status
	return &cloudInst, nil
}

// generateDeploymentPayload creates credentials and the user-data deployment script.
func (p *Provider) generateDeploymentPayload(planRAM int, tuning deploy.DeploymentTuning) (instanceCredentials, string, error) {
	creds := instanceCredentials{
		ssPassword:       deploy.GenerateRandomPassword(22),
		hysteriaPassword: deploy.GenerateRandomPassword(22),
		trojanPassword:   deploy.GenerateRandomPassword(22),
		vlessUUID:        deploy.GenerateUUID(),
		ports:            deploy.AllocatePorts(tuning.PortProfile),
	}

	if planRAM <= 600 {
		userData := deploy.GenerateLightweightScript(creds.ports.SSPort, creds.ssPassword)
		return creds, userData, nil
	}

	var err error
	creds.realityPrivateKey, creds.realityPublicKey, err = deploy.GenerateRealityKeyPair()
	if err != nil {
		return creds, "", fmt.Errorf("failed to generate reality key pair: %w", err)
	}
	creds.realityShortID = generateShortID()

	userData := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort:           creds.ports.SSPort,
		SSPassword:       creds.ssPassword,
		HysteriaPort:     creds.ports.HysteriaPort,
		HysteriaPassword: creds.hysteriaPassword,
		HysteriaServer:   tuning.HysteriaServerName,
		HysteriaMasqURL:  tuning.HysteriaMasqueradeURL,
		VLESSPort:        creds.ports.VLESSPort,
		VLESSUUID:        creds.vlessUUID,
		VLESSPrivateKey:  creds.realityPrivateKey,
		VLESSPublicKey:   creds.realityPublicKey,
		VLESSShortID:     creds.realityShortID,
		VLESSServer:      tuning.VLESSServerName,
		TrojanPort:       creds.ports.TrojanPort,
		TrojanPassword:   creds.trojanPassword,
		TrojanServer:     tuning.TrojanServerName,
		VLESSRelayPort:   creds.ports.VLESSRelayPort,
		SingBoxVersion:   tuning.SingBoxVersion,
		SingBoxFallback:  tuning.SingBoxFallbackVersion,
	})
	return creds, userData, nil
}

// createVultrInstance calls the Vultr API with OS ID fallback.
func (p *Provider) createVultrInstance(ctx context.Context, opts *cloud.CreateInstanceOptions, osIDs []int, userData string) (struct {
	Instance vultrInstance `json:"instance"`
}, int, error) {
	requestBody := map[string]any{
		"region":      opts.Region,
		"plan":        opts.Plan,
		"label":       opts.Label,
		"enable_ipv6": true,
		"user_data":   base64.StdEncoding.EncodeToString([]byte(userData)),
	}
	if sshKeyID := strings.TrimSpace(opts.SSHKeyID); sshKeyID != "" {
		requestBody["sshkey_id"] = []string{sshKeyID}
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	var lastErr error
	selectedOSID := 0

	for _, osID := range osIDs {
		requestBody["os_id"] = osID
		res, err := p.apiRequest(ctx, http.MethodPost, "/instances", requestBody)
		if err != nil {
			lastErr = err
			continue
		}
		var attempt struct {
			Instance vultrInstance `json:"instance"`
		}
		if err := p.parseResponse(res, &attempt); err != nil {
			msg := strings.ToLower(err.Error())
			if strings.Contains(msg, "os_id") || strings.Contains(msg, "os id") {
				lastErr = err
				continue
			}
			return payload, 0, err
		}
		payload = attempt
		selectedOSID = osID
		lastErr = nil
		break
	}
	if lastErr != nil {
		return payload, 0, lastErr
	}
	return payload, selectedOSID, nil
}

// buildNodeRecord constructs the initial node record for persistence.
func (p *Provider) buildNodeRecord(instanceID string, opts *cloud.CreateInstanceOptions, osID, planRAM int, creds instanceCredentials, tuning deploy.DeploymentTuning) nodeRecord {
	record := nodeRecord{
		InstanceID: instanceID,
		Label:      opts.Label,
		Region:     opts.Region,
		InstanceRecord: cloud.InstanceRecord{
			Plan:       opts.Plan,
			OSID:       osID,
			Port:       creds.ports.SSPort,
			Password:   creds.ssPassword,
			CreatedAt:  time.Now().UTC().Format(time.RFC3339),
			SSPort:     creds.ports.SSPort,
			SSPassword: creds.ssPassword,
		},
	}
	if planRAM > 600 {
		record.HysteriaPort = creds.ports.HysteriaPort
		record.HysteriaPassword = creds.hysteriaPassword
		record.HysteriaServerName = tuning.HysteriaServerName
		record.HysteriaInsecure = deploy.BoolPtr(tuning.HysteriaInsecure)
		record.VLESSPort = creds.ports.VLESSPort
		record.VLESSUUID = creds.vlessUUID
		record.VLESSPublicKey = creds.realityPublicKey
		record.VLESSShortID = creds.realityShortID
		record.VLESSServerName = tuning.VLESSServerName
		record.TrojanPort = creds.ports.TrojanPort
		record.TrojanPassword = creds.trojanPassword
		record.TrojanServerName = tuning.TrojanServerName
		record.TrojanInsecure = deploy.BoolPtr(tuning.TrojanInsecure)
		record.VLESSRelayPort = creds.ports.VLESSRelayPort
	}
	return record
}

// persistNodeRecord saves the node record to disk.
func (p *Provider) persistNodeRecord(instanceID string, record nodeRecord) error {
	records, err := p.loadNodeRecords()
	if err != nil {
		return err
	}
	records[instanceID] = record
	return p.saveNodeRecords(records)
}

// updateRecordFromInstance updates the persisted record with live instance data.
func (p *Provider) updateRecordFromInstance(instanceID string, instance vultrInstance, record nodeRecord) nodeRecord {
	records, err := p.loadNodeRecords()
	if err != nil {
		return record
	}
	rec := records[instanceID]
	if instance.MainIP != "" {
		rec.IPv4 = instance.MainIP
	}
	if instance.V6MainIP != "" {
		rec.IPv6 = instance.V6MainIP
	}
	if instance.Label != "" && rec.Label != instance.Label {
		rec.Label = instance.Label
	}
	if instance.Region != "" && rec.Region != instance.Region {
		rec.Region = instance.Region
	}
	rec.InstanceID = instanceID
	records[instanceID] = rec
	_ = p.saveNodeRecords(records)
	return rec
}

// waitForServiceReady waits for protocol TCP ports to become reachable.
func (p *Provider) waitForServiceReady(ctx context.Context, ip string, ports deploy.PortAssignment, planRAM int, extra map[string]string) {
	readyPorts := []int{ports.SSPort}
	if planRAM > 600 {
		readyPorts = append(readyPorts, ports.VLESSPort, ports.TrojanPort)
	}
	readyTimeout := parseServiceReadyTimeout(extra, defaultServiceReadyTimeout)
	if readyErr := p.waitForTCPPorts(ctx, ip, readyPorts, readyTimeout); readyErr != nil {
		fmt.Printf("[VultrProvider] Warning: %v\n", readyErr)
	}
}

// DestroyInstance destroys a Vultr instance.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if strings.TrimSpace(instanceID) == "" {
		return cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return err
	}

	res, err := p.apiRequest(ctx, http.MethodDelete, "/instances/"+instanceID, nil)
	if err != nil {
		return err
	}
	if err := p.parseResponse(res, nil); err != nil {
		return err
	}

	records, err := p.loadNodeRecords()
	if err == nil {
		if _, ok := records[instanceID]; ok {
			delete(records, instanceID)
			_ = p.saveNodeRecords(records)
		}
	}

	return nil
}

// GetInstance retrieves a specific Vultr instance.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/instances/"+instanceID, nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		records = map[string]nodeRecord{}
	}
	record := records[instanceID]
	if ensureManagedTLSDefaults(&record.InstanceRecord) {
		records[instanceID] = record
		_ = p.saveNodeRecords(records)
	}

	instance := toCloudInstance(payload.Instance, record)
	instance.Region = payload.Instance.Region
	instance.Status = payload.Instance.Status
	return &instance, nil
}

func (p *Provider) waitForInstance(ctx context.Context, instanceID string, timeout time.Duration) (vultrInstance, error) {
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	var lastErr error

	for {
		select {
		case <-waitCtx.Done():
			if lastErr != nil {
				return vultrInstance{}, lastErr
			}
			return vultrInstance{}, errors.New("timeout waiting for instance to become active")
		case <-ticker.C:
			inst, err := p.getInstanceRaw(waitCtx, instanceID)
			if err != nil {
				lastErr = err
				continue
			}
			if inst.Status == "active" && inst.MainIP != "" {
				return inst, nil
			}
		}
	}
}

func (p *Provider) getInstanceRaw(ctx context.Context, instanceID string) (vultrInstance, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/instances/"+instanceID, nil)
	if err != nil {
		return vultrInstance{}, err
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return vultrInstance{}, err
	}

	return payload.Instance, nil
}

// CleanInvalidNodes removes node records that lack proxy configuration.
// Returns the number of records removed.
func (p *Provider) CleanInvalidNodes(ctx context.Context) (int, error) {
	records, err := p.loadNodeRecords()
	if err != nil {
		return 0, fmt.Errorf("failed to load node records: %w", err)
	}

	removed := 0
	validRecords := make(map[string]nodeRecord)

	for id, record := range records {
		if validateNodeRecord(record) {
			validRecords[id] = record
		} else {
			fmt.Printf("[CleanInvalidNodes] Removing invalid node: %s (label=%s, ssPort=%d)\n",
				id, record.Label, record.SSPort)
			removed++
		}
	}

	if removed > 0 {
		fmt.Printf("[CleanInvalidNodes] Saving %d valid records (removed %d invalid)\n", len(validRecords), removed)
		if err := p.saveNodeRecords(validRecords); err != nil {
			return 0, fmt.Errorf("failed to save cleaned records: %w", err)
		}
		fmt.Printf("[CleanInvalidNodes] Successfully saved cleaned records to %s\n", p.nodesPath)
	}

	return removed, nil
}
