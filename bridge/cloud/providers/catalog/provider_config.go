package catalog

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		return &cloud.ProviderConfig{Provider: p.name, Extra: map[string]string{}}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}
	if len(data) == 0 {
		return &cloud.ProviderConfig{Provider: p.name, Extra: map[string]string{}}, nil
	}

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}
	if cfg.Provider == "" {
		cfg.Provider = p.name
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	migrated, err := cloud.RestoreProviderAPIKey(p.configPath, &cfg)
	if err != nil {
		return nil, err
	}
	if migrated {
		sanitized, err := cloud.PrepareProviderConfigForSave(p.configPath, &cfg)
		if err != nil {
			return nil, err
		}
		data, err := json.MarshalIndent(sanitized, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("failed to marshal sanitized config: %w", err)
		}
		if err := os.WriteFile(p.configPath, data, 0o600); err != nil {
			return nil, fmt.Errorf("failed to rewrite sanitized config: %w", err)
		}
	}
	p.config = &cfg
	return &cfg, nil
}

func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider == "" {
		config.Provider = p.name
	}
	if config.Provider != p.name {
		return fmt.Errorf("invalid provider: expected %s, got %s", p.name, config.Provider)
	}
	if config.Extra == nil {
		config.Extra = map[string]string{}
	}
	if err := os.MkdirAll(filepath.Dir(p.configPath), 0o755); err != nil {
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
		return fmt.Errorf("failed to write config: %w", err)
	}
	p.config = config
	if p.name == "contabo" {
		p.tokenMu.Lock()
		p.token = ""
		p.tokenExpiry = time.Time{}
		p.tokenMu.Unlock()
	}
	return nil
}

func (p *Provider) ValidateConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider == "" {
		config.Provider = p.name
	}
	if config.Provider != p.name {
		return fmt.Errorf("invalid provider: expected %s, got %s", p.name, config.Provider)
	}
	if strings.TrimSpace(config.APIKey) == "" {
		return cloud.ErrMissingAPIKey
	}
	return nil
}

func (p *Provider) getEffectiveConfig() (*cloud.ProviderConfig, error) {
	if p.config != nil && strings.TrimSpace(p.config.Provider) == p.name {
		return p.config, nil
	}
	cfg, err := p.LoadConfig()
	if err != nil {
		return nil, err
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}
	p.config = cfg
	return cfg, nil
}
