package digitalocean

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

const (
	baseURL           = "https://api.digitalocean.com/v2"
	configFileRelPath = "data/cloud/digitalocean-config.json"
	nodesFileRelPath  = "data/cloud/digitalocean-nodes.json"
)

var digitaloceanNodesMu sync.Mutex

// Provider implements cloud.CloudProvider for DigitalOcean
type Provider struct {
	config     *cloud.ProviderConfig
	client     *http.Client
	configPath string
	nodesPath  string
}

// New creates a new DigitalOcean provider instance
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "digitalocean",
		}
	}

	// Get base path from environment or use current directory
	basePath := os.Getenv("PRIVATEDEPLOY_BASE_PATH")
	if basePath == "" {
		basePath, _ = os.Getwd()
	}

	configPath := filepath.Join(basePath, configFileRelPath)
	nodesPath := filepath.Join(basePath, nodesFileRelPath)

	transport := &http.Transport{
		Proxy: nil,
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		IdleConnTimeout:       90 * time.Second,
	}

	return &Provider{
		config:     config,
		client:     &http.Client{Timeout: 30 * time.Second, Transport: transport},
		configPath: configPath,
		nodesPath:  nodesPath,
	}
}

// Name returns the provider identifier
func (p *Provider) Name() string {
	return "digitalocean"
}

// DisplayName returns the human-readable provider name
func (p *Provider) DisplayName() string {
	return "DigitalOcean"
}

// LoadConfig loads the DigitalOcean configuration from file
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		// Return empty config if file doesn't exist
		return &cloud.ProviderConfig{
			Provider: "digitalocean",
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config cloud.ProviderConfig
	if len(data) == 0 {
		config.Provider = "digitalocean"
		return &config, nil
	}

	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	// Update in-memory config
	p.config = &config
	return &config, nil
}

// SaveConfig saves the DigitalOcean configuration to file
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "digitalocean" {
		return fmt.Errorf("invalid provider: expected digitalocean, got %s", config.Provider)
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
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, err
	}

	return records, nil
}

func (p *Provider) saveNodeRecords(records map[string]cloud.InstanceRecord) error {
	digitaloceanNodesMu.Lock()
	defer digitaloceanNodesMu.Unlock()

	if err := os.MkdirAll(filepath.Dir(p.nodesPath), os.ModePerm); err != nil {
		return err
	}

	data, err := json.MarshalIndent(records, "", "  ")
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

// ValidateConfig validates the DigitalOcean configuration
func (p *Provider) ValidateConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider != "digitalocean" {
		return fmt.Errorf("invalid provider: expected digitalocean, got %s", config.Provider)
	}
	if config.APIKey == "" {
		return cloud.ErrMissingAPIKey
	}
	return nil
}

// ListRegions returns available DigitalOcean regions
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/regions", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Regions []struct {
			Slug      string   `json:"slug"`
			Name      string   `json:"name"`
			Available bool     `json:"available"`
			Features  []string `json:"features"`
		} `json:"regions"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	regions := make([]cloud.Region, 0)
	for _, r := range result.Regions {
		if !r.Available {
			continue
		}
		// Parse city and country from region name
		city, country := parseRegionName(r.Name)
		regions = append(regions, cloud.Region{
			ID:      r.Slug,
			City:    city,
			Country: country,
		})
	}

	return regions, nil
}

// ListPlans returns available DigitalOcean droplet sizes
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/sizes", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var result struct {
		Sizes []struct {
			Slug         string   `json:"slug"`
			Memory       int      `json:"memory"`
			VCPUs        int      `json:"vcpus"`
			Disk         int      `json:"disk"`
			Transfer     float64  `json:"transfer"`
			PriceMonthly float64  `json:"price_monthly"`
			PriceHourly  float64  `json:"price_hourly"`
			Available    bool     `json:"available"`
			Regions      []string `json:"regions"`
			Description  string   `json:"description"`
		} `json:"sizes"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	plans := make([]cloud.Plan, 0)
	for _, s := range result.Sizes {
		if !s.Available {
			continue
		}
		// Filter by region if specified
		if region != "" && !contains(s.Regions, region) {
			continue
		}

		plans = append(plans, cloud.Plan{
			ID:          s.Slug,
			Description: s.Description,
			RAM:         s.Memory,
			VCPUs:       s.VCPUs,
			Disk:        s.Disk,
			Bandwidth:   int(s.Transfer * 1024), // Convert TB to GB
			MonthlyCost: s.PriceMonthly,
			HourlyCost:  s.PriceHourly,
			Type:        "standard",
			Locations:   s.Regions,
		})
	}

	return plans, nil
}

// ListAvailability returns available sizes for a region
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
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

// ListInstances returns all DigitalOcean droplets
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var result struct {
		Droplets []struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
			Networks struct {
				V4 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v4"`
				V6 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v6"`
			} `json:"networks"`
		} `json:"droplets"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	dirty := false
	seen := make(map[string]struct{}, len(result.Droplets))

	instances := make([]cloud.Instance, 0, len(result.Droplets))
	for _, d := range result.Droplets {
		instanceID := fmt.Sprintf("cloud-do-%d", d.ID)
		instance := cloud.Instance{
			ID:        instanceID,
			Provider:  "digitalocean",
			Label:     d.Name,
			Status:    d.Status,
			Region:    d.Region.Slug,
			Plan:      d.Size.Slug,
			CreatedAt: d.CreatedAt,
		}

		record, ok := records[instanceID]
		if !ok {
			record = cloud.InstanceRecord{}
		}

		// Extract IPv4 (public)
		for _, net := range d.Networks.V4 {
			if net.Type == "public" {
				instance.IPv4 = net.IPAddress
				if record.IPv4 != instance.IPv4 {
					record.IPv4 = instance.IPv4
					dirty = true
				}
				break
			}
		}

		// Extract IPv6 (public)
		for _, net := range d.Networks.V6 {
			if net.Type == "public" {
				instance.IPv6 = net.IPAddress
				if record.IPv6 != instance.IPv6 {
					record.IPv6 = instance.IPv6
					dirty = true
				}
				break
			}
		}

		if record.Plan != d.Size.Slug {
			record.Plan = d.Size.Slug
			dirty = true
		}
		if ensureManagedTLSDefaults(&record) {
			dirty = true
		}

		createdAtStr := d.CreatedAt.Format(time.RFC3339)
		if record.CreatedAt != createdAtStr {
			record.CreatedAt = createdAtStr
			dirty = true
		}

		if record.SSPort != 0 {
			instance.SSPort = record.SSPort
		}
		if record.SSPassword != "" {
			instance.SSPassword = record.SSPassword
		}
		if record.HysteriaPort != 0 {
			instance.HysteriaPort = record.HysteriaPort
		}
		if record.HysteriaPassword != "" {
			instance.HysteriaPassword = record.HysteriaPassword
		}
		if record.HysteriaServerName != "" {
			instance.HysteriaServerName = record.HysteriaServerName
		}
		if record.HysteriaInsecure != nil {
			instance.HysteriaInsecure = record.HysteriaInsecure
		}
		if record.VLESSPort != 0 {
			instance.VLESSPort = record.VLESSPort
		}
		if record.VLESSUUID != "" {
			instance.VLESSUUID = record.VLESSUUID
		}
		if record.VLESSPublicKey != "" {
			instance.VLESSPublicKey = record.VLESSPublicKey
		}
		if record.VLESSShortID != "" {
			instance.VLESSShortID = record.VLESSShortID
		}
		if record.VLESSServerName != "" {
			instance.VLESSServerName = record.VLESSServerName
		}
		if record.TrojanPort != 0 {
			instance.TrojanPort = record.TrojanPort
		}
		if record.TrojanPassword != "" {
			instance.TrojanPassword = record.TrojanPassword
		}
		if record.TrojanServerName != "" {
			instance.TrojanServerName = record.TrojanServerName
		}
		if record.TrojanInsecure != nil {
			instance.TrojanInsecure = record.TrojanInsecure
		}

		records[instanceID] = record
		seen[instanceID] = struct{}{}

		instances = append(instances, instance)
	}

	if len(records) > len(seen) {
		for id := range records {
			if _, ok := seen[id]; !ok {
				dirty = true
				delete(records, id)
			}
		}
	}

	if dirty {
		if err := p.saveNodeRecords(records); err != nil {
			return nil, err
		}
	}

	return instances, nil
}

// CreateInstance creates a new DigitalOcean droplet
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	extra := mergeExtra(nil, opts.Extra)
	if p.config != nil {
		extra = mergeExtra(p.config.Extra, opts.Extra)
	}
	tuning := deploy.ResolveDeploymentTuning(extra)
	ports := deploy.AllocatePorts(tuning.PortProfile)
	if tuning.PortProfile == deploy.DefaultPortProfile {
		ports = deploy.PortAssignment{
			SSPort:       23650,
			HysteriaPort: 23651,
			VLESSPort:    23652,
			TrojanPort:   23653,
		}
	}

	// Generate credentials for all protocols
	ssPort := ports.SSPort
	ssPassword := deploy.GenerateRandomPassword(16)
	hysteriaPort := ports.HysteriaPort
	hysteriaPassword := deploy.GenerateRandomPassword(22)
	vlessPort := ports.VLESSPort
	vlessUUID := deploy.GenerateUUID()
	trojanPort := ports.TrojanPort
	trojanPassword := deploy.GenerateRandomPassword(22)

	// Generate Reality keypair
	realityPrivateKey, realityPublicKey, err := deploy.GenerateRealityKeyPair()
	if err != nil {
		fmt.Printf("Warning: failed to generate Reality keypair: %v\n", err)
		realityPrivateKey = ""
		realityPublicKey = ""
	}
	realityShortID := fmt.Sprintf("%016x", mathrand.Int63())

	// Generate cloud-init user data script
	userData := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort:           ssPort,
		SSPassword:       ssPassword,
		HysteriaPort:     hysteriaPort,
		HysteriaPassword: hysteriaPassword,
		HysteriaServer:   tuning.HysteriaServerName,
		HysteriaMasqURL:  tuning.HysteriaMasqueradeURL,
		VLESSPort:        vlessPort,
		VLESSUUID:        vlessUUID,
		VLESSPrivateKey:  realityPrivateKey,
		VLESSPublicKey:   realityPublicKey,
		VLESSShortID:     realityShortID,
		VLESSServer:      tuning.VLESSServerName,
		TrojanPort:       trojanPort,
		TrojanPassword:   trojanPassword,
		TrojanServer:     tuning.TrojanServerName,
		SingBoxVersion:   tuning.SingBoxVersion,
		SingBoxFallback:  tuning.SingBoxFallbackVersion,
	})
	if userData == "" {
		return nil, fmt.Errorf("failed to render deployment script")
	}

	// Prepare droplet creation request
	createReq := map[string]interface{}{
		"name":       opts.Label,
		"region":     opts.Region,
		"size":       opts.Plan,
		"image":      "debian-12-x64", // Debian 12
		"user_data":  userData,
		"monitoring": true,
		"ipv6":       true,
	}

	// Add SSH key if provided
	if opts.SSHKeyID != "" {
		// Try to convert SSH key ID to integer, or use as string
		if keyID, err := strconv.Atoi(opts.SSHKeyID); err == nil {
			createReq["ssh_keys"] = []interface{}{keyID}
		} else {
			createReq["ssh_keys"] = []interface{}{opts.SSHKeyID}
		}
	}

	reqBody, err := json.Marshal(createReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/droplets", bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Droplet struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
		} `json:"droplet"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	instanceID := fmt.Sprintf("cloud-do-%d", result.Droplet.ID)

	instance := &cloud.Instance{
		ID:                 instanceID,
		Provider:           "digitalocean",
		Label:              result.Droplet.Name,
		Status:             result.Droplet.Status,
		Region:             result.Droplet.Region.Slug,
		Plan:               result.Droplet.Size.Slug,
		CreatedAt:          result.Droplet.CreatedAt,
		SSPort:             ssPort,
		SSPassword:         ssPassword,
		HysteriaPort:       hysteriaPort,
		HysteriaPassword:   hysteriaPassword,
		HysteriaServerName: tuning.HysteriaServerName,
		HysteriaInsecure:   deploy.BoolPtr(tuning.HysteriaInsecure),
		VLESSPort:          vlessPort,
		VLESSUUID:          vlessUUID,
		VLESSPublicKey:     realityPublicKey,
		VLESSShortID:       realityShortID,
		VLESSServerName:    tuning.VLESSServerName,
		TrojanPort:         trojanPort,
		TrojanPassword:     trojanPassword,
		TrojanServerName:   tuning.TrojanServerName,
		TrojanInsecure:     deploy.BoolPtr(tuning.TrojanInsecure),
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	record := cloud.InstanceRecord{
		Plan:               opts.Plan,
		CreatedAt:          result.Droplet.CreatedAt.Format(time.RFC3339),
		SSPort:             ssPort,
		SSPassword:         ssPassword,
		HysteriaPort:       hysteriaPort,
		HysteriaPassword:   hysteriaPassword,
		HysteriaServerName: tuning.HysteriaServerName,
		HysteriaInsecure:   deploy.BoolPtr(tuning.HysteriaInsecure),
		VLESSPort:          vlessPort,
		VLESSUUID:          vlessUUID,
		VLESSPublicKey:     realityPublicKey,
		VLESSShortID:       realityShortID,
		VLESSServerName:    tuning.VLESSServerName,
		TrojanPort:         trojanPort,
		TrojanPassword:     trojanPassword,
		TrojanServerName:   tuning.TrojanServerName,
		TrojanInsecure:     deploy.BoolPtr(tuning.TrojanInsecure),
	}

	if instance.IPv4 != "" {
		record.IPv4 = instance.IPv4
	}

	if instance.IPv6 != "" {
		record.IPv6 = instance.IPv6
	}

	records[instanceID] = record

	if err := p.saveNodeRecords(records); err != nil {
		return nil, err
	}

	// Ensure firewall exists and associate it with the new droplet
	firewallID, err := p.ensurePrivateDeployFirewall(ctx, ports)
	if err != nil {
		// Log error but don't fail the instance creation
		// The instance was created successfully, just without firewall
		fmt.Printf("Warning: failed to create/get firewall: %v\n", err)
	} else {
		// Associate firewall with droplet
		if err := p.associateFirewallWithDroplet(ctx, firewallID, result.Droplet.ID); err != nil {
			fmt.Printf("Warning: failed to associate firewall with droplet: %v\n", err)
		}
	}

	return instance, nil
}

// DestroyInstance destroys a DigitalOcean droplet
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if instanceID == "" {
		return cloud.ErrInstanceNotFound
	}

	// DigitalOcean API expects the numeric droplet ID. Instances in PrivateDeploy are
	// prefixed with "cloud-do-", so strip that prefix if present.
	actualID := strings.TrimPrefix(instanceID, "cloud-do-")
	if actualID == "" {
		return cloud.ErrInstanceNotFound
	}

	req, err := http.NewRequestWithContext(ctx, "DELETE", baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		_ = p.deleteNodeRecord(instanceID)
		return nil
	}

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	return p.deleteNodeRecord(instanceID)
}

// GetInstance retrieves a specific DigitalOcean droplet
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	actualID := strings.TrimPrefix(instanceID, "cloud-do-")
	if actualID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		_ = p.deleteNodeRecord(instanceID)
		return nil, cloud.ErrInstanceNotFound
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Droplet struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
			Networks struct {
				V4 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v4"`
				V6 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v6"`
			} `json:"networks"`
		} `json:"droplet"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	instance := &cloud.Instance{
		ID:        fmt.Sprintf("cloud-do-%d", result.Droplet.ID),
		Provider:  "digitalocean",
		Label:     result.Droplet.Name,
		Status:    result.Droplet.Status,
		Region:    result.Droplet.Region.Slug,
		Plan:      result.Droplet.Size.Slug,
		CreatedAt: result.Droplet.CreatedAt,
	}

	// Extract IPv4 (public)
	for _, net := range result.Droplet.Networks.V4 {
		if net.Type == "public" {
			instance.IPv4 = net.IPAddress
			break
		}
	}

	// Extract IPv6 (public)
	for _, net := range result.Droplet.Networks.V6 {
		if net.Type == "public" {
			instance.IPv6 = net.IPAddress
			break
		}
	}

	records, err := p.loadNodeRecords()
	if err == nil {
		record := records[instance.ID]
		updated := false

		if instance.IPv4 != "" && record.IPv4 != instance.IPv4 {
			record.IPv4 = instance.IPv4
			updated = true
		}
		if instance.IPv6 != "" && record.IPv6 != instance.IPv6 {
			record.IPv6 = instance.IPv6
			updated = true
		}
		plan := result.Droplet.Size.Slug
		if record.Plan != plan {
			record.Plan = plan
			updated = true
		}
		createdAtStr := result.Droplet.CreatedAt.Format(time.RFC3339)
		if record.CreatedAt != createdAtStr {
			record.CreatedAt = createdAtStr
			updated = true
		}
		if ensureManagedTLSDefaults(&record) {
			updated = true
		}

		if record.SSPort != 0 {
			instance.SSPort = record.SSPort
		}
		if record.SSPassword != "" {
			instance.SSPassword = record.SSPassword
		}
		if record.HysteriaPort != 0 {
			instance.HysteriaPort = record.HysteriaPort
		}
		if record.HysteriaPassword != "" {
			instance.HysteriaPassword = record.HysteriaPassword
		}
		if record.HysteriaServerName != "" {
			instance.HysteriaServerName = record.HysteriaServerName
		}
		if record.HysteriaInsecure != nil {
			instance.HysteriaInsecure = record.HysteriaInsecure
		}
		if record.VLESSPort != 0 {
			instance.VLESSPort = record.VLESSPort
		}
		if record.VLESSUUID != "" {
			instance.VLESSUUID = record.VLESSUUID
		}
		if record.VLESSPublicKey != "" {
			instance.VLESSPublicKey = record.VLESSPublicKey
		}
		if record.VLESSShortID != "" {
			instance.VLESSShortID = record.VLESSShortID
		}
		if record.VLESSServerName != "" {
			instance.VLESSServerName = record.VLESSServerName
		}
		if record.TrojanPort != 0 {
			instance.TrojanPort = record.TrojanPort
		}
		if record.TrojanPassword != "" {
			instance.TrojanPassword = record.TrojanPassword
		}
		if record.TrojanServerName != "" {
			instance.TrojanServerName = record.TrojanServerName
		}
		if record.TrojanInsecure != nil {
			instance.TrojanInsecure = record.TrojanInsecure
		}

		records[instance.ID] = record
		if updated {
			_ = p.saveNodeRecords(records)
		}
	}

	return instance, nil
}

// Helper functions

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

func parseRegionName(name string) (city, country string) {
	// Map DigitalOcean region names to bilingual display with Chinese translation
	// Format: "English Name (中文翻译)"
	regionMap := map[string]struct {
		City    string
		Country string
	}{
		"New York 1":       {"New York 1 (纽约1)", "US"},
		"New York 2":       {"New York 2 (纽约2)", "US"},
		"New York 3":       {"New York 3 (纽约3)", "US"},
		"San Francisco 1":  {"San Francisco 1 (旧金山1)", "US"},
		"San Francisco 2":  {"San Francisco 2 (旧金山2)", "US"},
		"San Francisco 3":  {"San Francisco 3 (旧金山3)", "US"},
		"Toronto 1":        {"Toronto 1 (多伦多1)", "CA"},
		"London 1":         {"London 1 (伦敦1)", "GB"},
		"Frankfurt 1":      {"Frankfurt 1 (法兰克福1)", "DE"},
		"Amsterdam 1":      {"Amsterdam 1 (阿姆斯特丹1)", "NL"},
		"Amsterdam 2":      {"Amsterdam 2 (阿姆斯特丹2)", "NL"},
		"Amsterdam 3":      {"Amsterdam 3 (阿姆斯特丹3)", "NL"},
		"Singapore 1":      {"Singapore 1 (新加坡1)", "SG"},
		"Bangalore 1":      {"Bangalore 1 (班加罗尔1)", "IN"},
		"Sydney 1":         {"Sydney 1 (悉尼1)", "AU"},
		"San Jose 1":       {"San Jose 1 (圣何塞1)", "US"},
		"Silicon Valley 1": {"Silicon Valley 1 (硅谷1)", "US"},
		"Atlanta 1":        {"Atlanta 1 (亚特兰大1)", "US"},
	}

	if region, ok := regionMap[name]; ok {
		return region.City, region.Country
	}

	// Fallback: use the name as-is (API name)
	return name, "Unknown"
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

// ensurePrivateDeployFirewall ensures a protocol-specific PrivateDeploy firewall exists and returns its ID.
func (p *Provider) ensurePrivateDeployFirewall(ctx context.Context, ports deploy.PortAssignment) (string, error) {
	firewallName := fmt.Sprintf("privatedeploy-%d-%d-%d-%d", ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort)

	// First, check if this firewall already exists
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/firewalls", nil)
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var listResult struct {
		Firewalls []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"firewalls"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&listResult); err != nil {
		return "", err
	}

	// Check if matching firewall already exists
	for _, fw := range listResult.Firewalls {
		if fw.Name == firewallName {
			return fw.ID, nil
		}
	}

	// Create new firewall
	firewallReq := map[string]interface{}{
		"name": firewallName,
		"inbound_rules": []map[string]interface{}{
			{
				"protocol": "tcp",
				"ports":    "22",
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.SSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    fmt.Sprintf("%d", ports.SSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    fmt.Sprintf("%d", ports.HysteriaPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.VLESSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.TrojanPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
		},
		"outbound_rules": []map[string]interface{}{
			{
				"protocol": "tcp",
				"ports":    "all",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    "all",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "icmp",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
		},
	}

	reqBody, err := json.Marshal(firewallReq)
	if err != nil {
		return "", fmt.Errorf("failed to marshal firewall request: %w", err)
	}

	createReq, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/firewalls", bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}

	createReq.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	createReq.Header.Set("Content-Type", "application/json")

	createResp, err := p.client.Do(createReq)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer createResp.Body.Close()

	if createResp.StatusCode != http.StatusCreated && createResp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(createResp.Body)
		return "", fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, createResp.StatusCode, string(body))
	}

	var createResult struct {
		Firewall struct {
			ID string `json:"id"`
		} `json:"firewall"`
	}

	if err := json.NewDecoder(createResp.Body).Decode(&createResult); err != nil {
		return "", fmt.Errorf("failed to decode firewall creation response: %w", err)
	}

	return createResult.Firewall.ID, nil
}

// associateFirewallWithDroplet associates a firewall with a droplet
func (p *Provider) associateFirewallWithDroplet(ctx context.Context, firewallID string, dropletID int) error {
	reqBody := map[string]interface{}{
		"droplet_ids": []int{dropletID},
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/firewalls/"+firewallID+"/droplets", bytes.NewReader(body))
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(respBody))
	}

	return nil
}
