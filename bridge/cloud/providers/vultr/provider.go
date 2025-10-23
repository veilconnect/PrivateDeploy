package vultr

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"veildeploy/bridge/cloud"
)

const (
	configFileRelPath = "data/cloud/vultr-config.json"
	nodesFileRelPath  = "data/cloud/vultr-nodes.json"
	vultrAPIBaseURL   = "https://api.vultr.com/v2"
)

var (
	vultrHTTPClient = &http.Client{Timeout: 60 * time.Second}
	nodesMu         sync.Mutex
)

// Provider implements cloud.CloudProvider for Vultr
type Provider struct {
	config     *cloud.ProviderConfig
	configPath string
	nodesPath  string
}

// vultrNode represents the stored node configuration
type vultrNode struct {
	Plan             string `json:"plan"`
	OSID             int    `json:"osId"`
	IPv4             string `json:"ipv4"`
	IPv6             string `json:"ipv6,omitempty"`
	Port             int    `json:"port"`
	Password         string `json:"password"`
	CreatedAt        string `json:"createdAt"`
	SSPort           int    `json:"ssPort,omitempty"`
	SSPassword       string `json:"ssPassword,omitempty"`
	HysteriaPort     int    `json:"hysteriaPort,omitempty"`
	HysteriaPassword string `json:"hysteriaPassword,omitempty"`
	VLESSPort        int    `json:"vlessPort,omitempty"`
	VLESSUUID        string `json:"vlessUUID,omitempty"`
	VLESSPublicKey   string `json:"vlessPublicKey,omitempty"`
	VLESSShortID     string `json:"vlessShortID,omitempty"`
	TrojanPort       int    `json:"trojanPort,omitempty"`
	TrojanPassword   string `json:"trojanPassword,omitempty"`
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

// New creates a new Vultr provider instance
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "vultr",
		}
	}

	// Get base path from environment or use current directory
	basePath := os.Getenv("VEILDEPLOY_BASE_PATH")
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
	if err := os.WriteFile(p.configPath, data, 0644); err != nil {
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

// ListRegions returns available Vultr regions
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	// This will be implemented by calling existing Vultr API functions
	// For now, return empty list
	return []cloud.Region{}, nil
}

// ListPlans returns available Vultr plans for a region
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	// This will be implemented by calling existing Vultr API functions
	return []cloud.Plan{}, nil
}

// ListAvailability returns available plans for a region
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	// This will be implemented by calling existing Vultr API functions
	return []string{}, nil
}

// ListInstances returns all Vultr instances
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	// For now, this will be implemented by calling the existing App.ListVultrInstances
	// which is already used by the frontend
	return []cloud.Instance{}, fmt.Errorf("ListInstances not yet implemented for Vultr provider - please use the legacy ListVultrInstances")
}

// CreateInstance creates a new Vultr instance
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	// For now, this will be implemented by calling the existing App.CreateVultrInstance
	return nil, fmt.Errorf("CreateInstance not yet implemented for Vultr provider - please use the legacy CreateVultrInstance")
}

// DestroyInstance destroys a Vultr instance
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	// For now, this will be implemented by calling the existing App.DestroyVultrInstance
	return fmt.Errorf("DestroyInstance not yet implemented for Vultr provider - please use the legacy DestroyVultrInstance")
}

// GetInstance retrieves a specific Vultr instance
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	// This will be implemented by calling existing Vultr API functions
	return nil, cloud.ErrInstanceNotFound
}

// Helper functions to convert between Vultr-specific and generic types

func toCloudRegion(vr interface{}) cloud.Region {
	// Convert Vultr region to cloud.Region
	return cloud.Region{}
}

func toCloudPlan(vp interface{}) cloud.Plan {
	// Convert Vultr plan to cloud.Plan
	return cloud.Plan{}
}

func toCloudInstance(vi interface{}) cloud.Instance {
	// Convert Vultr instance to cloud.Instance
	return cloud.Instance{}
}

func fromCloudInstanceOptions(opts *cloud.CreateInstanceOptions) interface{} {
	// Convert cloud.CreateInstanceOptions to Vultr format
	return nil
}
