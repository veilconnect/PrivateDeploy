package bridge

import (
	"context"
	"encoding/json"
	"log"

	"privatedeploy/bridge/cloud"
)

// CloudProviderInfo represents basic information about a cloud provider
type CloudProviderInfo struct {
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
}

// ListCloudProviders returns all available cloud providers
func (a *App) ListCloudProviders() FlagResult {
	log.Printf("[CloudBridge] ListCloudProviders called")

	providerNames := a.CloudManager.ListProviders()
	providers := make([]CloudProviderInfo, 0, len(providerNames))

	for _, name := range providerNames {
		provider, err := a.CloudManager.GetProvider(name)
		if err != nil {
			log.Printf("[CloudBridge] Warning: Failed to get provider %s: %v", name, err)
			continue
		}

		providers = append(providers, CloudProviderInfo{
			Name:        provider.Name(),
			DisplayName: provider.DisplayName(),
		})
	}

	data, err := json.Marshal(providers)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal providers: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Found %d providers: %s", len(providers), string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// SetCloudProvider sets the active cloud provider
func (a *App) SetCloudProvider(providerName string) FlagResult {
	log.Printf("[CloudBridge] SetCloudProvider called with: %s", providerName)

	err := a.CloudManager.SetActiveProvider(providerName)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to set provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Successfully set active provider to: %s", providerName)
	return FlagResult{Flag: true, Data: providerName}
}

// GetCloudProvider returns the current active provider
func (a *App) GetCloudProvider() FlagResult {
	log.Printf("[CloudBridge] GetCloudProvider called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	info := CloudProviderInfo{
		Name:        provider.Name(),
		DisplayName: provider.DisplayName(),
	}

	data, err := json.Marshal(info)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal provider info: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Current provider: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// GetCloudConfig returns the persisted configuration for the active provider
func (a *App) GetCloudConfig() FlagResult {
	log.Printf("[CloudBridge] GetCloudConfig called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	cfg, err := provider.LoadConfig()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to load config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if cfg == nil {
		cfg = &cloud.ProviderConfig{}
	}
	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Loaded config for provider %s", cfg.Provider)
	return FlagResult{Flag: true, Data: string(data)}
}

// SaveCloudConfig persists configuration for the active provider
func (a *App) SaveCloudConfig(configJSON string) FlagResult {
	log.Printf("[CloudBridge] SaveCloudConfig called with payload length: %d", len(configJSON))

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse config JSON: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	if cfg.Provider != provider.Name() {
		errMsg := "config provider mismatch with active provider"
		log.Printf("[CloudBridge] ERROR: %s (config=%s, active=%s)", errMsg, cfg.Provider, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	if err := provider.ValidateConfig(&cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Config validation failed: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if err := provider.SaveConfig(&cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to save config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Config saved for provider %s (defaultRegion=%s, defaultPlan=%s)", cfg.Provider, cfg.DefaultRegion, cfg.DefaultPlan)
	return FlagResult{Flag: true, Data: "Success"}
}

// ListCloudInstances returns all instances for the active provider
func (a *App) ListCloudInstances() FlagResult {
	log.Printf("[CloudBridge] ListCloudInstances called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	instances, err := provider.ListInstances(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instances)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d instances for provider %s", len(instances), provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// CreateCloudInstance creates a new instance on the active provider
func (a *App) CreateCloudInstance(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateCloudInstance called with options: %s", optionsJSON)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var opts cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse options: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	instance, err := provider.CreateInstance(ctx, &opts)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to create instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instance)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Created instance %s on provider %s", instance.ID, provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// DestroyCloudInstance destroys an instance on the active provider
func (a *App) DestroyCloudInstance(instanceID string) FlagResult {
	log.Printf("[CloudBridge] DestroyCloudInstance called for instance: %s", instanceID)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	if err := provider.DestroyInstance(ctx, instanceID); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to destroy instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Destroyed instance %s on provider %s", instanceID, provider.Name())
	return FlagResult{Flag: true, Data: "Instance destroyed successfully"}
}

// ListCloudRegions returns all regions for the active provider
func (a *App) ListCloudRegions() FlagResult {
	log.Printf("[CloudBridge] ListCloudRegions called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	regions, err := provider.ListRegions(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(regions)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d regions for provider %s", len(regions), provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// ListCloudPlans returns all plans for the active provider
func (a *App) ListCloudPlans() FlagResult {
	log.Printf("[CloudBridge] ListCloudPlans called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	plans, err := provider.ListPlans(ctx, "")
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d plans for provider %s", len(plans), provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// ListCloudAvailability returns plan availability for the active provider
func (a *App) ListCloudAvailability(region string) FlagResult {
	log.Printf("[CloudBridge] ListCloudAvailability called for region: %s", region)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	plans, err := provider.ListAvailability(ctx, region)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d available plans for provider %s region %s", len(plans), provider.Name(), region)
	return FlagResult{Flag: true, Data: string(data)}
}
