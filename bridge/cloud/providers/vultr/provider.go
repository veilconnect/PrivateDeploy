// Package vultr implements the cloud.CloudProvider interface for Vultr.
//
// The package is split across several files by responsibility:
//
//   - provider.go        — package shell: types, config, validation, HTTP transport.
//   - regions_plans.go   — ListRegions / ListPlans / ListAvailability + OS / plan lookups.
//   - instances.go       — instance lifecycle: List, Create, Get, Destroy, CleanInvalidNodes.
//   - firewall.go        — firewall group + rule management.
//   - node_records.go    — local node-record persistence and matching.
//   - helpers.go         — small shared helpers (TLS defaults, port probes, short IDs).
//   - latency.go         — region latency benchmarking.
//   - userdata_recovery.go — recovers credentials from VPS user-data when local state is stale.
package vultr

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
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
	nodesMu     sync.Mutex
	osCache     []vultrOS
	osCacheTime time.Time
	osCacheMu   sync.Mutex
)

const (
	defaultServiceReadyTimeout = 8 * time.Minute
	serviceReadyProbeInterval  = 5 * time.Second
	serviceReadyDialTimeout    = 2 * time.Second
)

// Provider implements cloud.CloudProvider for Vultr.
type Provider struct {
	config     *cloud.ProviderConfig
	configPath string
	nodesPath  string
}

// nodeRecord is the on-disk representation of a managed node, including legacy fields
// kept for compatibility with older state files.
type nodeRecord struct {
	InstanceID string `json:"instanceId,omitempty"`
	Label      string `json:"label,omitempty"`
	Region     string `json:"region,omitempty"`
	cloud.InstanceRecord
}

// vultrInstance mirrors the Vultr API instance response.
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

// New creates a new Vultr provider instance.
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "vultr",
		}
	}

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

// Name returns the provider identifier.
func (p *Provider) Name() string {
	return "vultr"
}

// DisplayName returns the human-readable provider name.
func (p *Provider) DisplayName() string {
	return "Vultr"
}

// LoadConfig loads the Vultr configuration from disk.
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
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

	p.config = &config
	return &config, nil
}

// SaveConfig saves the Vultr configuration to disk.
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "vultr" {
		return fmt.Errorf("invalid provider: expected vultr, got %s", config.Provider)
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

func mustJSON(config *cloud.ProviderConfig) []byte {
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		panic(err)
	}
	return data
}

// ValidateConfig validates the Vultr configuration.
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
