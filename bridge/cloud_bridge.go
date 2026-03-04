package bridge

import (
	"context"
	"encoding/json"
	"log"
	"sync"

	"privatedeploy/bridge/cloud"
	sshprovider "privatedeploy/bridge/cloud/providers/ssh"

	"github.com/wailsapp/wails/v2/pkg/runtime"
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

// TestCloudRegionLatency tests latency for a specific region on the active provider
func (a *App) TestCloudRegionLatency(regionCode string) FlagResult {
	log.Printf("[CloudBridge] TestCloudRegionLatency called for region: %s", regionCode)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Check if provider supports latency testing (currently only Vultr)
	type LatencyTester interface {
		TestRegionLatency(ctx context.Context, regionCode string) (interface{}, error)
	}

	tester, ok := provider.(LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx := context.Background()
	result, err := tester.TestRegionLatency(ctx, regionCode)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to test region latency: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal latency result: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Latency test completed for region %s: %s", regionCode, string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// TestAllCloudRegions tests latency for all regions on the active provider
func (a *App) TestAllCloudRegions() FlagResult {
	log.Printf("[CloudBridge] TestAllCloudRegions called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Check if provider supports latency testing
	type LatencyTester interface {
		TestAllRegions(ctx context.Context) (interface{}, error)
	}

	tester, ok := provider.(LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx := context.Background()
	results, err := tester.TestAllRegions(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to test all regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(results)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal latency results: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Latency test completed for all regions")
	return FlagResult{Flag: true, Data: string(data)}
}

// GetFastestCloudRegion returns the fastest available region based on latency test
func (a *App) GetFastestCloudRegion() FlagResult {
	log.Printf("[CloudBridge] GetFastestCloudRegion called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Check if provider supports latency testing
	type LatencyTester interface {
		GetFastestRegion(ctx context.Context) (interface{}, error)
	}

	tester, ok := provider.(LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx := context.Background()
	result, err := tester.GetFastestRegion(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to get fastest region: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal fastest region: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Fastest region: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// CleanInvalidCloudNodes removes node records with incomplete proxy configuration
func (a *App) CleanInvalidCloudNodes() FlagResult {
	log.Printf("[CloudBridge] CleanInvalidCloudNodes called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Check if provider supports node cleaning
	type NodeCleaner interface {
		CleanInvalidNodes(ctx context.Context) (int, error)
	}

	cleaner, ok := provider.(NodeCleaner)
	if !ok {
		errMsg := "node cleaning not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx := context.Background()
	removed, err := cleaner.CleanInvalidNodes(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to clean invalid nodes: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	result := map[string]interface{}{
		"provider": provider.Name(),
		"removed":  removed,
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal result: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Cleaned %d invalid nodes for provider %s", removed, provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// TestSSHConnection tests SSH connectivity with the given configuration
func (a *App) TestSSHConnection(configJSON string) FlagResult {
	log.Printf("[CloudBridge] TestSSHConnection called")

	var extra map[string]string
	if err := json.Unmarshal([]byte(configJSON), &extra); err != nil {
		return FlagResult{Flag: false, Data: "invalid config JSON: " + err.Error()}
	}

	provider, err := a.CloudManager.GetProvider("ssh")
	if err != nil {
		return FlagResult{Flag: false, Data: "SSH provider not registered: " + err.Error()}
	}

	sshProvider, ok := provider.(*sshprovider.Provider)
	if !ok {
		return FlagResult{Flag: false, Data: "failed to get SSH provider instance"}
	}

	info, err := sshProvider.TestConnection(extra)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(info)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] SSH connection test success: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// SetupSSHEventEmitter configures the SSH provider to emit Wails events.
// Called from OnStartup when the context is available.
func (a *App) SetupSSHEventEmitter() {
	provider, err := a.CloudManager.GetProvider("ssh")
	if err != nil {
		return
	}
	sshProvider, ok := provider.(*sshprovider.Provider)
	if !ok {
		return
	}
	sshProvider.SetEventEmitter(func(eventName string, data ...interface{}) {
		runtime.EventsEmit(a.Ctx, eventName, data...)
	})
}

// MultiDeployResult holds the result of a batch deployment.
type MultiDeployResult struct {
	ID      string `json:"id"`
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
}

// CreateMultipleCloudInstances deploys multiple instances in parallel (max 3 concurrent).
func (a *App) CreateMultipleCloudInstances(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateMultipleCloudInstances called")

	var optsList []cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &optsList); err != nil {
		return FlagResult{Flag: false, Data: "invalid options JSON: " + err.Error()}
	}

	if len(optsList) == 0 {
		return FlagResult{Flag: false, Data: "no instances to create"}
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	results := make([]MultiDeployResult, len(optsList))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 3) // max 3 concurrent deploys

	for i, opts := range optsList {
		wg.Add(1)
		go func(idx int, o cloud.CreateInstanceOptions) {
			defer wg.Done()
			sem <- struct{}{}        // acquire
			defer func() { <-sem }() // release

			runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, "deploying", o.Label)

			ctx := context.Background()
			instance, err := provider.CreateInstance(ctx, &o)
			if err != nil {
				results[idx] = MultiDeployResult{Success: false, Error: err.Error()}
				runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, "failed", err.Error())
				return
			}

			results[idx] = MultiDeployResult{ID: instance.ID, Success: true}
			runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, "ready", instance.ID)
		}(i, opts)
	}

	wg.Wait()

	data, err := json.Marshal(results)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Multi-deploy complete: %d instances", len(optsList))
	return FlagResult{Flag: true, Data: string(data)}
}

// ScoreCloudRegions scores and ranks regions for deployment suitability.
func (a *App) ScoreCloudRegions(latenciesJSON string) FlagResult {
	log.Printf("[CloudBridge] ScoreCloudRegions called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx := context.Background()
	regions, err := provider.ListRegions(ctx)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var latencies map[string]float64
	if latenciesJSON != "" {
		if err := json.Unmarshal([]byte(latenciesJSON), &latencies); err != nil {
			latencies = make(map[string]float64)
		}
	} else {
		latencies = make(map[string]float64)
	}

	scores := cloud.ScoreRegions(regions, latencies)

	data, err := json.Marshal(scores)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Scored %d regions", len(scores))
	return FlagResult{Flag: true, Data: string(data)}
}

// StartHealthMonitor starts periodic health checking for the active provider's nodes.
func (a *App) StartHealthMonitor() FlagResult {
	log.Printf("[CloudBridge] StartHealthMonitor called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	if a.HealthMonitor.IsRunning() {
		return FlagResult{Flag: true, Data: "already running"}
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	a.HealthMonitor.SetEventEmitter(func(event string, data ...interface{}) {
		runtime.EventsEmit(a.Ctx, event, data...)
	})

	a.HealthMonitor.Start(provider)
	return FlagResult{Flag: true, Data: "started"}
}

// StopHealthMonitor stops the health check loop.
func (a *App) StopHealthMonitor() FlagResult {
	log.Printf("[CloudBridge] StopHealthMonitor called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	a.HealthMonitor.Stop()
	return FlagResult{Flag: true, Data: "stopped"}
}

// GetHealthStatus returns the latest health check results.
func (a *App) GetHealthStatus() FlagResult {
	log.Printf("[CloudBridge] GetHealthStatus called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	jsonStr, err := a.HealthMonitor.GetResultsJSON()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: jsonStr}
}
