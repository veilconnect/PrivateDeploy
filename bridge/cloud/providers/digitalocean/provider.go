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
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/persistence"
)

// baseURL is a variable (not a const) so tests can point the provider at a
// fake API server.
var baseURL = "https://api.digitalocean.com/v2"

const (
	configFileRelPath = "data/cloud/digitalocean-config.json"
	nodesFileRelPath  = "data/cloud/digitalocean-nodes.json"

	defaultServiceReadyTimeout = 8 * time.Minute
	serviceReadyProbeInterval  = 5 * time.Second
	serviceReadyDialTimeout    = 2 * time.Second
)

var (
	digitaloceanNodesMu          sync.Mutex
	digitaloceanFirewallMu       sync.Mutex
	digitaloceanInstanceCreateMu sync.Mutex
	digitaloceanActiveCreates    = make(map[string]int)
)

type nodeRecord struct {
	cloud.InstanceRecord
	ManagedSSHKeyFingerprint string `json:"managedSshKeyFingerprint,omitempty"`
	FirewallGroupID          string `json:"firewallGroupId,omitempty"`
	FirewallOwnershipToken   string `json:"firewallOwnershipToken,omitempty"`
	FirewallCleanupPending   bool   `json:"firewallCleanupPending,omitempty"`
}

// Provider implements cloud.CloudProvider for DigitalOcean.
type Provider struct {
	configMu        sync.Mutex
	managedSSHKeyMu sync.Mutex
	config          *cloud.ProviderConfig
	client          *http.Client
	basePath        string
	configPath      string
	nodesPath       string
	// saveManagedSSHSecret is replaceable in package tests so persistence
	// failures can be proven to stop before any account or billable API POST.
	saveManagedSSHSecret func(string, string, string) error
	// generateRealityKeyPair is replaceable in package tests so a local
	// cryptographic failure can be proven to stop before any cloud mutation.
	generateRealityKeyPair func() (string, string, error)
}

func (p *Provider) instanceCreateKey(instanceID string) string {
	return p.nodesPath + "\x00" + instanceID
}

func (p *Provider) beginInstanceCreate(instanceID string) {
	digitaloceanInstanceCreateMu.Lock()
	digitaloceanActiveCreates[p.instanceCreateKey(instanceID)]++
	digitaloceanInstanceCreateMu.Unlock()
}

func (p *Provider) endInstanceCreate(instanceID string) {
	digitaloceanInstanceCreateMu.Lock()
	key := p.instanceCreateKey(instanceID)
	if digitaloceanActiveCreates[key] <= 1 {
		delete(digitaloceanActiveCreates, key)
	} else {
		digitaloceanActiveCreates[key]--
	}
	digitaloceanInstanceCreateMu.Unlock()
}

func (p *Provider) isInstanceCreateActive(instanceID string) bool {
	digitaloceanInstanceCreateMu.Lock()
	defer digitaloceanInstanceCreateMu.Unlock()
	return digitaloceanActiveCreates[p.instanceCreateKey(instanceID)] > 0
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
		config:                 cloneProviderConfig(config),
		client:                 &http.Client{Timeout: 30 * time.Second, Transport: transport},
		basePath:               basePath,
		configPath:             configPath,
		nodesPath:              nodesPath,
		saveManagedSSHSecret:   cloud.SaveSecret,
		generateRealityKeyPair: deploy.GenerateRealityKeyPair,
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
	p.configMu.Lock()
	defer p.configMu.Unlock()
	return p.loadConfigLocked()
}

// loadConfigLocked loads configuration while configMu is held.
func (p *Provider) loadConfigLocked() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		p.config = &cloud.ProviderConfig{
			Provider: "digitalocean",
		}
		return cloneProviderConfig(p.config), nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config cloud.ProviderConfig
	if len(data) == 0 {
		config.Provider = "digitalocean"
		p.config = cloneProviderConfig(&config)
		return cloneProviderConfig(p.config), nil
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
		if err := persistence.WritePrivateFileAtomic(p.configPath, data); err != nil {
			return nil, fmt.Errorf("failed to rewrite sanitized config file: %w", err)
		}
	}

	p.config = cloneProviderConfig(&config)
	return cloneProviderConfig(p.config), nil
}

// SaveConfig saves the DigitalOcean configuration to disk.
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	config = cloneProviderConfig(config)
	p.configMu.Lock()
	defer p.configMu.Unlock()

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

	if err := persistence.WritePrivateFileAtomic(p.configPath, data); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}

	p.config = cloneProviderConfig(config)
	return nil
}

// ensureConfig makes sure the in-memory config carries an API key before any
// authenticated API call. The defaults registry constructs this provider with
// an empty config, so after a process restart a direct CreateInstance (without
// a prior GetConfig/SaveConfig round-trip) would otherwise send an empty
// "Bearer " header. LoadConfig already restores the key from the OS secret
// store, so reuse it here — same pattern as the Vultr provider's ensureConfig.
// When the in-memory config already has a key, no disk access happens.
func (p *Provider) ensureConfig() (*cloud.ProviderConfig, error) {
	p.configMu.Lock()
	defer p.configMu.Unlock()

	if p.config == nil || strings.TrimSpace(p.config.APIKey) == "" {
		cfg, err := p.loadConfigLocked()
		if err != nil {
			return nil, err
		}
		p.config = cloneProviderConfig(cfg)
	}
	if strings.TrimSpace(p.config.APIKey) == "" {
		return nil, cloud.ErrMissingAPIKey
	}
	return cloneProviderConfig(p.config), nil
}

func cloneProviderConfig(config *cloud.ProviderConfig) *cloud.ProviderConfig {
	if config == nil {
		return nil
	}
	clone := *config
	if config.Extra != nil {
		clone.Extra = make(map[string]string, len(config.Extra))
		for key, value := range config.Extra {
			clone.Extra[key] = value
		}
	}
	return &clone
}

func (p *Provider) apiKey() (string, error) {
	cfg, err := p.ensureConfig()
	if err != nil {
		return "", err
	}
	return cfg.APIKey, nil
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
