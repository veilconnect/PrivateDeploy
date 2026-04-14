package vultr

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

const (
	configFileRelPath = "data/cloud/vultr-config.json"
	nodesFileRelPath  = "data/cloud/vultr-nodes.json"
)

var (
	vultrAPIBaseURL = "https://api.vultr.com/v2"
	vultrHTTPClient = &http.Client{
		Timeout: 60 * time.Second,
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: (&net.Dialer{
				Timeout:   30 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
			IdleConnTimeout:       90 * time.Second,
		},
	}
	nodesMu         sync.Mutex
	osCache         []vultrOS
	osCacheTime     time.Time
	osCacheMu       sync.Mutex
)

const (
	defaultServiceReadyTimeout = 8 * time.Minute
	serviceReadyProbeInterval  = 5 * time.Second
	serviceReadyDialTimeout    = 2 * time.Second
)

// Provider implements cloud.CloudProvider for Vultr
type Provider struct {
	config     *cloud.ProviderConfig
	configPath string
	nodesPath  string
}

// nodeRecord represents the stored node configuration, including legacy fields for compatibility.
type nodeRecord struct {
	InstanceID string `json:"instanceId,omitempty"`
	Label      string `json:"label,omitempty"`
	Region     string `json:"region,omitempty"`
	cloud.InstanceRecord
}

// vultrInstance represents Vultr API instance response
type vultrInstance struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Status    string `json:"status"`
	Region    string `json:"region"`
	MainIP    string `json:"main_ip"`
	V6MainIP  string `json:"v6_main_ip"`
	CreatedAt string `json:"created_at"`
}

type vultrRegion struct {
	ID        string `json:"id"`
	City      string `json:"city"`
	Country   string `json:"country"`
	Continent string `json:"continent"`
}

type vultrPlan struct {
	ID          string   `json:"id"`
	Description string   `json:"description"`
	MemoryMB    int      `json:"ram"`
	VCPUs       int      `json:"vcpu_count"`
	DiskGB      int      `json:"disk"`
	BandwidthGB int      `json:"bandwidth"`
	MonthlyCost float64  `json:"monthly_cost"`
	HourlyCost  float64  `json:"hourly_cost"`
	Type        string   `json:"type"`
	Locations   []string `json:"locations"`
}

type vultrOS struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Family string `json:"family"`
}

type vultrFirewallGroup struct {
	ID           string `json:"id"`
	Description  string `json:"description"`
	DateCreated  string `json:"date_created"`
	RuleCount    int    `json:"rule_count"`
	MaxRuleCount int    `json:"max_rule_count"`
}

type vultrFirewallRule struct {
	ID         int    `json:"id,omitempty"`
	IPType     string `json:"ip_type"`
	Protocol   string `json:"protocol"`
	Subnet     string `json:"subnet"`
	SubnetSize int    `json:"subnet_size"`
	Port       string `json:"port,omitempty"`
	Notes      string `json:"notes,omitempty"`
}

// New creates a new Vultr provider instance
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "vultr",
		}
	}

	// Get base path from environment or use current directory
	basePath := os.Getenv("PRIVATEDEPLOY_BASE_PATH")
	if basePath == "" {
		basePath, _ = os.Getwd()
	}

	configPath := filepath.Join(basePath, configFileRelPath)
	nodesPath := filepath.Join(basePath, nodesFileRelPath)

	return &Provider{
		config:     config,
		configPath: configPath,
		nodesPath:  nodesPath,
	}
}

// Name returns the provider identifier
func (p *Provider) Name() string {
	return "vultr"
}

// DisplayName returns the human-readable provider name
func (p *Provider) DisplayName() string {
	return "Vultr"
}

// LoadConfig loads the Vultr configuration from file
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		// Return empty config if file doesn't exist
		return &cloud.ProviderConfig{
			Provider: "vultr",
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config cloud.ProviderConfig
	if len(data) == 0 {
		config.Provider = "vultr"
		return &config, nil
	}

	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	migrated, err := cloud.RestoreProviderAPIKey(p.configPath, &config)
	if err != nil {
		return nil, err
	}
	if migrated {
		sanitized, err := cloud.PrepareProviderConfigForSave(p.configPath, &config)
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(p.configPath, mustJSON(sanitized), 0o600); err != nil {
			return nil, fmt.Errorf("failed to rewrite sanitized config: %w", err)
		}
	}

	// Update in-memory config
	p.config = &config
	return &config, nil
}

// SaveConfig saves the Vultr configuration to file
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "vultr" {
		return fmt.Errorf("invalid provider: expected vultr, got %s", config.Provider)
	}

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(p.configPath), 0o750); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	sanitized, err := cloud.PrepareProviderConfigForSave(p.configPath, config)
	if err != nil {
		return err
	}

	// Marshal config to JSON
	data, err := json.MarshalIndent(sanitized, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Write to file
	if err := os.WriteFile(p.configPath, data, 0o600); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}

	// Update in-memory config
	p.config = config
	return nil
}

func mustJSON(config *cloud.ProviderConfig) []byte {
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		panic(err)
	}
	return data
}

// ValidateConfig validates the Vultr configuration
func (p *Provider) ValidateConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider != "vultr" {
		return fmt.Errorf("invalid provider: expected vultr, got %s", config.Provider)
	}
	if config.APIKey == "" {
		return cloud.ErrMissingAPIKey
	}
	return nil
}

func (p *Provider) ensureConfig() (*cloud.ProviderConfig, error) {
	if p.config == nil || strings.TrimSpace(p.config.APIKey) == "" {
		cfg, err := p.LoadConfig()
		if err != nil {
			return nil, err
		}
		p.config = cfg
	}
	if strings.TrimSpace(p.config.APIKey) == "" {
		return nil, cloud.ErrMissingAPIKey
	}
	return p.config, nil
}

func (p *Provider) apiRequest(ctx context.Context, method, path string, payload any) (*http.Response, error) {
	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}

	var reader io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, vultrAPIBaseURL+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	req.Header.Set("Content-Type", "application/json")

	return vultrHTTPClient.Do(req)
}

func decodeVultrError(body []byte) string {
	var env struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}

	if err := json.Unmarshal(body, &env); err == nil {
		if env.Error.Message != "" {
			return env.Error.Message
		}
		if len(env.Errors) > 0 && env.Errors[0].Message != "" {
			return env.Errors[0].Message
		}
	}

	return strings.TrimSpace(string(body))
}

func (p *Provider) parseResponse(res *http.Response, v any) error {
	defer res.Body.Close()

	body, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}

	if res.StatusCode >= 400 {
		reason := decodeVultrError(body)
		if reason == "" {
			reason = http.StatusText(res.StatusCode)
		}
		return fmt.Errorf("vultr api error (%d %s): %s", res.StatusCode, http.StatusText(res.StatusCode), reason)
	}

	if v == nil || len(body) == 0 {
		return nil
	}

	return json.Unmarshal(body, v)
}

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

// ListRegions returns available Vultr regions
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/regions", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Regions []vultrRegion `json:"regions"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	regions := make([]cloud.Region, 0, len(payload.Regions))
	for _, region := range payload.Regions {
		regions = append(regions, cloud.Region{
			ID:        region.ID,
			City:      region.City,
			Country:   region.Country,
			Continent: region.Continent,
		})
	}

	sort.Slice(regions, func(i, j int) bool {
		if regions[i].Country == regions[j].Country {
			return regions[i].City < regions[j].City
		}
		return regions[i].Country < regions[j].Country
	})

	return regions, nil
}

// ListPlans returns available Vultr plans for a region
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/plans", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	plans := make([]cloud.Plan, 0, len(payload.Plans))
	for _, plan := range payload.Plans {
		if region != "" && len(plan.Locations) > 0 {
			found := false
			for _, loc := range plan.Locations {
				if loc == region {
					found = true
					break
				}
			}
			if !found {
				continue
			}
		}

		plans = append(plans, cloud.Plan{
			ID:          plan.ID,
			Description: plan.Description,
			RAM:         plan.MemoryMB,
			VCPUs:       plan.VCPUs,
			Disk:        plan.DiskGB,
			Bandwidth:   plan.BandwidthGB,
			MonthlyCost: plan.MonthlyCost,
			HourlyCost:  plan.HourlyCost,
			Type:        plan.Type,
			Locations:   plan.Locations,
		})
	}

	sort.Slice(plans, func(i, j int) bool {
		if plans[i].RAM == plans[j].RAM {
			return plans[i].ID < plans[j].ID
		}
		return plans[i].RAM < plans[j].RAM
	})

	return plans, nil
}

// ListAvailability returns available plans for a region
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	if strings.TrimSpace(region) == "" {
		return nil, fmt.Errorf("region is required")
	}

	plans, err := p.ListPlans(ctx, region)
	if err != nil {
		return nil, err
	}

	availability := make([]string, 0, len(plans))
	for _, plan := range plans {
		availability = append(availability, plan.ID)
	}
	return availability, nil
}

// ListInstances returns all Vultr instances
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

// CreateInstance creates a new Vultr instance
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

	// Generate credentials and user-data script
	creds, userData, err := p.generateDeploymentPayload(planRAM, tuning)
	if err != nil {
		return nil, err
	}

	// Create the instance via Vultr API (with OS fallback)
	payload, selectedOSID, err := p.createVultrInstance(ctx, opts, osIDs, userData)
	if err != nil {
		return nil, err
	}

	instanceID := payload.Instance.ID

	// Build and persist the node record
	record := p.buildNodeRecord(instanceID, opts, selectedOSID, planRAM, creds, tuning)
	if err := p.persistNodeRecord(instanceID, record); err != nil {
		return nil, err
	}

	// Wait for instance to become active, then configure firewall and verify ports
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

// instanceCredentials holds generated credentials for a deployment.
type instanceCredentials struct {
	ssPassword       string
	hysteriaPassword string
	trojanPassword   string
	vlessUUID        string
	realityPrivateKey string
	realityPublicKey  string
	realityShortID    string
	ports            deploy.PortAssignment
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

// updateRecordFromInstance updates the persisted record with live instance data (IP, label, etc.).
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

// configureInstanceFirewall sets up Vultr firewall rules for the instance.
func (p *Provider) configureInstanceFirewall(ctx context.Context, instanceID string, ports deploy.PortAssignment, label string) {
	firewallID, err := p.ensureFirewallGroup(ctx, requiredFirewallRuleCount(ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort))
	if err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to ensure firewall group: %v\n", err)
		return
	}
	if err := p.ensureFirewallRules(ctx, firewallID, ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort, label); err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to configure firewall rules: %v\n", err)
		return
	}
	if err := p.attachFirewallToInstance(ctx, instanceID, firewallID); err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to attach firewall: %v\n", err)
	}
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

// DestroyInstance destroys a Vultr instance
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

// GetInstance retrieves a specific Vultr instance
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

func mergeExtra(base, override map[string]string) map[string]string {
	merged := make(map[string]string, len(base)+len(override))
	for k, v := range base {
		if strings.TrimSpace(k) != "" {
			merged[k] = v
		}
	}
	for k, v := range override {
		if strings.TrimSpace(k) != "" {
			merged[k] = v
		}
	}
	return merged
}

func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	if record == nil {
		return false
	}

	changed := false

	if record.HysteriaPort != 0 && record.HysteriaPassword != "" {
		if strings.TrimSpace(record.HysteriaServerName) == "" {
			record.HysteriaServerName = deploy.DefaultHysteriaServerName
			changed = true
		}
		if record.HysteriaInsecure == nil {
			record.HysteriaInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.TrojanPort != 0 && record.TrojanPassword != "" {
		if strings.TrimSpace(record.TrojanServerName) == "" {
			record.TrojanServerName = deploy.DefaultTrojanServerName
			changed = true
		}
		if record.TrojanInsecure == nil {
			record.TrojanInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.VLESSPort != 0 && record.VLESSUUID != "" {
		if strings.TrimSpace(record.VLESSServerName) == "" {
			if strings.TrimSpace(record.TrojanServerName) != "" {
				record.VLESSServerName = record.TrojanServerName
			} else {
				record.VLESSServerName = deploy.DefaultVLESSServerName
			}
			changed = true
		}
	}

	return changed
}

func (p *Provider) getPlanRAM(ctx context.Context, planID string) (int, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/plans", nil)
	if err != nil {
		return 0, err
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return 0, err
	}

	for _, plan := range payload.Plans {
		if plan.ID == planID {
			return plan.MemoryMB, nil
		}
	}
	return 0, fmt.Errorf("plan %s not found", planID)
}

func (p *Provider) preferredOSIDs(ctx context.Context) ([]int, error) {
	osList, err := p.listOperatingSystems(ctx)
	if err != nil {
		return nil, err
	}

	var result []int

	addMatches := func(predicate func(vultrOS) bool) {
		for _, os := range osList {
			if predicate(os) {
				appendUniqueInt(&result, os.ID)
			}
		}
	}

	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "11")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "20.04")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "12")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "22.04")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "24.04")
	})
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian")
	})
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu")
	})
	for _, os := range osList {
		appendUniqueInt(&result, os.ID)
	}

	return result, nil
}

func (p *Provider) listOperatingSystems(ctx context.Context) ([]vultrOS, error) {
	osCacheMu.Lock()
	defer osCacheMu.Unlock()

	if len(osCache) > 0 && time.Since(osCacheTime) < time.Hour {
		cached := make([]vultrOS, len(osCache))
		copy(cached, osCache)
		return cached, nil
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/os", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		OperatingSystems []vultrOS `json:"os"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	osCache = payload.OperatingSystems
	osCacheTime = time.Now()

	cached := make([]vultrOS, len(osCache))
	copy(cached, osCache)
	return cached, nil
}

func appendUniqueInt(list *[]int, candidate int) {
	for _, existing := range *list {
		if existing == candidate {
			return
		}
	}
	*list = append(*list, candidate)
}

// generateShortID returns a cryptographically random 16-character hex string
// suitable for use as a Reality short ID.
func generateShortID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return fmt.Sprintf("%016x", b)
}

func parseServiceReadyTimeout(extra map[string]string, fallback time.Duration) time.Duration {
	if len(extra) == 0 {
		return fallback
	}
	for _, key := range []string{
		"serviceReadyTimeoutSec",
		"service_ready_timeout_sec",
		"proxyReadyTimeoutSec",
		"proxy_ready_timeout_sec",
	} {
		raw := strings.TrimSpace(extra[key])
		if raw == "" {
			continue
		}
		sec, err := strconv.Atoi(raw)
		if err != nil || sec <= 0 {
			continue
		}
		return time.Duration(sec) * time.Second
	}
	return fallback
}

func (p *Provider) waitForTCPPorts(ctx context.Context, ip string, ports []int, timeout time.Duration) error {
	if strings.TrimSpace(ip) == "" {
		return nil
	}

	required := make([]int, 0, len(ports))
	seen := make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port <= 0 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		required = append(required, port)
	}
	if len(required) == 0 {
		return nil
	}

	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(serviceReadyProbeInterval)
	defer ticker.Stop()

	// Probe immediately, then on each tick.
	for {
		pending := make([]string, 0, len(required))
		allReady := true

		for _, port := range required {
			if isTCPPortReachable(ip, port, serviceReadyDialTimeout) {
				continue
			}
			allReady = false
			pending = append(pending, strconv.Itoa(port))
		}

		if allReady {
			return nil
		}

		select {
		case <-waitCtx.Done():
			return fmt.Errorf("timeout waiting for service ports on %s, pending tcp ports: %s", ip, strings.Join(pending, ","))
		case <-ticker.C:
		}
	}
}

func isTCPPortReachable(ip string, port int, timeout time.Duration) bool {
	address := net.JoinHostPort(ip, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
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

// ensureFirewallGroup gets or creates a firewall group for PrivateDeploy.
func (p *Provider) ensureFirewallGroup(ctx context.Context, requiredRules int) (string, error) {
	// List existing firewall groups
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls", nil)
	if err != nil {
		return "", fmt.Errorf("failed to list firewall groups: %w", err)
	}

	var listPayload struct {
		FirewallGroups []vultrFirewallGroup `json:"firewall_groups"`
	}
	if err := p.parseResponse(res, &listPayload); err != nil {
		return "", fmt.Errorf("failed to parse firewall groups: %w", err)
	}

	hasPrivateDeployGroup := false
	for _, fg := range listPayload.FirewallGroups {
		if strings.Contains(fg.Description, "PrivateDeploy") {
			hasPrivateDeployGroup = true
			if firewallGroupHasCapacity(fg, requiredRules) {
				return fg.ID, nil
			}
		}
	}

	// Fall back to any existing PrivateDeploy group when the API omits capacity metadata.
	for _, fg := range listPayload.FirewallGroups {
		if strings.Contains(fg.Description, "PrivateDeploy") && fg.MaxRuleCount == 0 && fg.RuleCount == 0 {
			return fg.ID, nil
		}
	}

	// Create a new firewall group
	description := "PrivateDeploy Auto-Managed Firewall"
	if hasPrivateDeployGroup {
		description = fmt.Sprintf("%s (%s)", description, time.Now().UTC().Format("20060102-150405"))
	}
	createPayload := map[string]any{
		"description": description,
	}

	res, err = p.apiRequest(ctx, http.MethodPost, "/firewalls", createPayload)
	if err != nil {
		return "", fmt.Errorf("failed to create firewall group: %w", err)
	}

	var createResult struct {
		FirewallGroup vultrFirewallGroup `json:"firewall_group"`
	}
	if err := p.parseResponse(res, &createResult); err != nil {
		return "", fmt.Errorf("failed to parse created firewall group: %w", err)
	}

	// Add default SSH rule.
	if err := p.addFirewallRule(ctx, createResult.FirewallGroup.ID, sshFirewallRule()); err != nil {
		return "", fmt.Errorf("failed to add SSH rule: %w", err)
	}

	return createResult.FirewallGroup.ID, nil
}

func firewallGroupHasCapacity(group vultrFirewallGroup, requiredRules int) bool {
	if requiredRules <= 0 {
		return true
	}
	if group.MaxRuleCount <= 0 {
		return false
	}
	return group.RuleCount+requiredRules <= group.MaxRuleCount
}

func requiredFirewallRuleCount(ssPort, hysteriaPort, vlessPort, trojanPort int) int {
	return len(firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort, ""))
}

func sshFirewallRule() vultrFirewallRule {
	return vultrFirewallRule{
		IPType:     "v4",
		Protocol:   "tcp",
		Subnet:     "0.0.0.0",
		SubnetSize: 0,
		Port:       "22",
		Notes:      "SSH Access",
	}
}

func firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort int, label string) []vultrFirewallRule {
	rules := []vultrFirewallRule{sshFirewallRule()}
	if ssPort > 0 {
		ssPortStr := strconv.Itoa(ssPort)
		rules = append(rules,
			vultrFirewallRule{
				IPType:     "v4",
				Protocol:   "tcp",
				Subnet:     "0.0.0.0",
				SubnetSize: 0,
				Port:       ssPortStr,
				Notes:      fmt.Sprintf("%s Shadowsocks TCP", label),
			},
			vultrFirewallRule{
				IPType:     "v4",
				Protocol:   "udp",
				Subnet:     "0.0.0.0",
				SubnetSize: 0,
				Port:       ssPortStr,
				Notes:      fmt.Sprintf("%s Shadowsocks UDP", label),
			},
		)
	}
	if hysteriaPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "udp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(hysteriaPort),
			Notes:      fmt.Sprintf("%s Hysteria2", label),
		})
	}
	if vlessPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "tcp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(vlessPort),
			Notes:      fmt.Sprintf("%s VLESS", label),
		})
	}
	if trojanPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "tcp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(trojanPort),
			Notes:      fmt.Sprintf("%s Trojan", label),
		})
	}
	return rules
}

func firewallRuleKey(protocol, port string) string {
	return fmt.Sprintf("%s:%s", protocol, port)
}

// addFirewallRule adds a rule to a firewall group
func (p *Provider) addFirewallRule(ctx context.Context, firewallID string, rule vultrFirewallRule) error {
	res, err := p.apiRequest(ctx, http.MethodPost, "/firewalls/"+firewallID+"/rules", rule)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	if res.StatusCode >= 400 {
		body, _ := io.ReadAll(res.Body)
		return fmt.Errorf("failed to add firewall rule: %s", decodeVultrError(body))
	}

	return nil
}

// ensureFirewallRules ensures all necessary firewall rules exist for the given ports
func (p *Provider) ensureFirewallRules(ctx context.Context, firewallID string, ssPort, hysteriaPort, vlessPort, trojanPort int, label string) error {
	// List existing rules
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls/"+firewallID+"/rules", nil)
	if err != nil {
		return fmt.Errorf("failed to list firewall rules: %w", err)
	}

	var listPayload struct {
		FirewallRules []vultrFirewallRule `json:"firewall_rules"`
	}
	if err := p.parseResponse(res, &listPayload); err != nil {
		return fmt.Errorf("failed to parse firewall rules: %w", err)
	}

	// Check which ports already have rules (using "protocol:port" as key to distinguish TCP/UDP)
	existingRules := make(map[string]bool)
	for _, rule := range listPayload.FirewallRules {
		existingRules[firewallRuleKey(rule.Protocol, rule.Port)] = true
	}

	for _, rule := range firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort, label) {
		if existingRules[firewallRuleKey(rule.Protocol, rule.Port)] {
			continue
		}
		if err := p.addFirewallRule(ctx, firewallID, rule); err != nil {
			return err
		}
	}

	return nil
}

// attachFirewallToInstance attaches a firewall group to an instance
func (p *Provider) attachFirewallToInstance(ctx context.Context, instanceID, firewallID string) error {
	payload := map[string]any{
		"firewall_group_id": firewallID,
	}

	res, err := p.apiRequest(ctx, http.MethodPatch, "/instances/"+instanceID, payload)
	if err != nil {
		return fmt.Errorf("failed to attach firewall: %w", err)
	}
	defer res.Body.Close()

	if res.StatusCode >= 400 {
		body, _ := io.ReadAll(res.Body)
		return fmt.Errorf("failed to attach firewall to instance: %s", decodeVultrError(body))
	}

	return nil
}

// ValidateNodeRecord checks if a node record has complete proxy configuration
func validateNodeRecord(record nodeRecord) bool {
	// A valid record must have at least Shadowsocks configuration
	if record.SSPort == 0 || record.SSPassword == "" {
		return false
	}
	// If port is set (for backward compatibility), it should match SSPort
	if record.Port != 0 && record.Port != record.SSPort {
		return false
	}
	return true
}

// CleanInvalidNodes removes node records that lack proxy configuration
// Returns the number of records removed
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
