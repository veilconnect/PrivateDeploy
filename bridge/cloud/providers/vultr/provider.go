package vultr

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

const (
	configFileRelPath = "data/cloud/vultr-config.json"
	nodesFileRelPath  = "data/cloud/vultr-nodes.json"
	vultrAPIBaseURL   = "https://api.vultr.com/v2"
)

var (
	vultrHTTPClient = &http.Client{Timeout: 60 * time.Second}
	nodesMu         sync.Mutex
	osCache         []vultrOS
	osCacheTime     time.Time
	osCacheMu       sync.Mutex
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
	if err := os.MkdirAll(filepath.Dir(p.configPath), os.ModePerm); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Marshal config to JSON
	data, err := json.MarshalIndent(config, "", "  ")
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

	if err := os.MkdirAll(filepath.Dir(p.nodesPath), os.ModePerm); err != nil {
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
		ID:               inst.ID,
		Provider:         "vultr",
		Label:            firstNonEmpty(inst.Label, record.Label),
		Status:           inst.Status,
		Region:           firstNonEmpty(inst.Region, record.Region),
		Plan:             record.Plan,
		OSID:             record.OSID,
		IPv4:             firstNonEmpty(inst.MainIP, record.IPv4),
		IPv6:             firstNonEmpty(inst.V6MainIP, record.IPv6),
		Port:             record.Port,
		Password:         record.Password,
		CreatedAt:        created,
		SSPort:           record.SSPort,
		SSPassword:       record.SSPassword,
		HysteriaPort:     record.HysteriaPort,
		HysteriaPassword: record.HysteriaPassword,
		VLESSPort:        record.VLESSPort,
		VLESSUUID:        record.VLESSUUID,
		VLESSPublicKey:   record.VLESSPublicKey,
		VLESSShortID:     record.VLESSShortID,
		TrojanPort:       record.TrojanPort,
		TrojanPassword:   record.TrojanPassword,
	}
}

func recordsToInstances(records map[string]nodeRecord) []cloud.Instance {
	instances := make([]cloud.Instance, 0, len(records))
	for id, record := range records {
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
	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/instances", nil)
	if err != nil {
		records, loadErr := p.loadNodeRecords()
		if loadErr != nil || len(records) == 0 {
			return nil, err
		}
		return recordsToInstances(records), nil
	}

	var payload struct {
		Instances []vultrInstance `json:"instances"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		records, loadErr := p.loadNodeRecords()
		if loadErr != nil || len(records) == 0 {
			return nil, err
		}
		return recordsToInstances(records), nil
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	dirty := false
	seen := make(map[string]struct{}, len(payload.Instances))
	instances := make([]cloud.Instance, 0, len(payload.Instances))

	for _, inst := range payload.Instances {
		record, ok := records[inst.ID]
		if !ok {
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

		records[inst.ID] = record
		seen[inst.ID] = struct{}{}
		instances = append(instances, toCloudInstance(inst, record))
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

	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

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

	basePort := randomPort()
	ssPort := basePort
	hysteriaPort := basePort + 1
	vlessPort := basePort + 2
	trojanPort := basePort + 3

	ssPassword := deploy.GenerateRandomPassword(22)
	hysteriaPassword := deploy.GenerateRandomPassword(22)
	trojanPassword := deploy.GenerateRandomPassword(22)
	vlessUUID := deploy.GenerateUUID()

	realityPrivateKey := ""
	realityPublicKey := ""
	realityShortID := ""

	var userData string
	if planRAM <= 600 {
		userData = deploy.GenerateLightweightScript(ssPort, ssPassword)
	} else {
		realityPrivateKey, realityPublicKey, err = deploy.GenerateRealityKeyPair()
		if err != nil {
			return nil, fmt.Errorf("failed to generate reality key pair: %w", err)
		}
		realityShortID = fmt.Sprintf("%016x", mathrand.Int63())

		userData = deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
			SSPort:           ssPort,
			SSPassword:       ssPassword,
			HysteriaPort:     hysteriaPort,
			HysteriaPassword: hysteriaPassword,
			VLESSPort:        vlessPort,
			VLESSUUID:        vlessUUID,
			VLESSPrivateKey:  realityPrivateKey,
			VLESSPublicKey:   realityPublicKey,
			VLESSShortID:     realityShortID,
			TrojanPort:       trojanPort,
			TrojanPassword:   trojanPassword,
		})
	}

	requestBody := map[string]any{
		"region":      opts.Region,
		"plan":        opts.Plan,
		"label":       opts.Label,
		"enable_ipv6": true,
		"user_data":   base64.StdEncoding.EncodeToString([]byte(userData)),
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
			return nil, err
		}

		payload = attempt
		selectedOSID = osID
		lastErr = nil
		break
	}

	if lastErr != nil {
		return nil, lastErr
	}

	instanceID := payload.Instance.ID

	record := nodeRecord{
		InstanceID: instanceID,
		Label:      opts.Label,
		Region:     opts.Region,
		InstanceRecord: cloud.InstanceRecord{
			Plan:       opts.Plan,
			OSID:       selectedOSID,
			Port:       ssPort,
			Password:   ssPassword,
			CreatedAt:  time.Now().UTC().Format(time.RFC3339),
			SSPort:     ssPort,
			SSPassword: ssPassword,
		},
	}

	if planRAM > 600 {
		record.HysteriaPort = hysteriaPort
		record.HysteriaPassword = hysteriaPassword
		record.VLESSPort = vlessPort
		record.VLESSUUID = vlessUUID
		record.VLESSPublicKey = realityPublicKey
		record.VLESSShortID = realityShortID
		record.TrojanPort = trojanPort
		record.TrojanPassword = trojanPassword
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	records[instanceID] = record
	if err := p.saveNodeRecords(records); err != nil {
		return nil, err
	}

	instance, err := p.waitForInstance(ctx, instanceID, 15*time.Minute)
	if err == nil {
		records, err = p.loadNodeRecords()
		if err == nil {
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
			record = rec
		}
	} else {
		instance = payload.Instance
	}

	cloudInst := toCloudInstance(instance, record)
	cloudInst.Region = payload.Instance.Region
	cloudInst.Status = payload.Instance.Status
	return &cloudInst, nil
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

	instance := toCloudInstance(payload.Instance, record)
	instance.Region = payload.Instance.Region
	instance.Status = payload.Instance.Status
	return &instance, nil
}

func randomPort() int {
	return 20000 + mathrand.Intn(30000)
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
