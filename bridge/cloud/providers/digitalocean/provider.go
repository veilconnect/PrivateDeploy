// Package digitalocean implements the cloud.CloudProvider interface for
// DigitalOcean droplets.
//
// Files in this package:
//
//   - provider.go        — package shell: types, config, validation.
//   - regions_plans.go   — ListRegions / ListPlans / ListAvailability + region naming.
//   - instances.go       — instance lifecycle: List, Create, Get, Destroy.
//   - firewall.go        — protocol-specific firewall create + droplet attach.
//   - node_records.go    — local droplet-record persistence.
//   - helpers.go         — small shared helpers (port probes, short IDs, TLS defaults).
//   - readiness.go       — protocol-level readiness probes + self-heal.
package digitalocean

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
)

const (
	baseURL           = "https://api.digitalocean.com/v2"
	configFileRelPath = "data/cloud/digitalocean-config.json"
	nodesFileRelPath  = "data/cloud/digitalocean-nodes.json"

	defaultServiceReadyTimeout = 8 * time.Minute
	serviceReadyProbeInterval  = 5 * time.Second
	serviceReadyDialTimeout    = 2 * time.Second
)

var digitaloceanNodesMu sync.Mutex

// Provider implements cloud.CloudProvider for DigitalOcean.
type Provider struct {
	config     *cloud.ProviderConfig
	client     *http.Client
	basePath   string
	configPath string
	nodesPath  string
}

// New creates a new DigitalOcean provider instance.
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "digitalocean",
		}
	}

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
		basePath:   basePath,
		configPath: configPath,
		nodesPath:  nodesPath,
	}
}

// Name returns the provider identifier.
func (p *Provider) Name() string {
	return "digitalocean"
}

// DisplayName returns the human-readable provider name.
func (p *Provider) DisplayName() string {
	return "DigitalOcean"
}

// LoadConfig loads the DigitalOcean configuration from disk.
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
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

	migrated, err := cloud.RestoreProviderAPIKey(p.configPath, &config)
	if err != nil {
		return nil, err
	}
	if migrated {
		sanitized, err := cloud.PrepareProviderConfigForSave(p.configPath, &config)
		if err != nil {
			return nil, err
		}
		data, err := json.MarshalIndent(sanitized, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("failed to marshal sanitized config: %w", err)
		}
		if err := os.WriteFile(p.configPath, data, 0o600); err != nil {
			return nil, fmt.Errorf("failed to rewrite sanitized config file: %w", err)
		}
	}

	p.config = &config
	return &config, nil
}

// SaveConfig saves the DigitalOcean configuration to disk.
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "digitalocean" {
		return fmt.Errorf("invalid provider: expected digitalocean, got %s", config.Provider)
	}

	if err := os.MkdirAll(filepath.Dir(p.configPath), 0o750); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	sanitized, err := cloud.PrepareProviderConfigForSave(p.configPath, config)
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(sanitized, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := os.WriteFile(p.configPath, data, 0o600); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}

	p.config = config
	return nil
}

// ValidateConfig validates the DigitalOcean configuration.
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
