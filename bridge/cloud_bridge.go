package bridge

import (
	"context"
	"encoding/json"
	"fmt"
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

func (a *App) ListCloudProvidersTyped() ([]CloudProviderInfo, error) {
	log.Printf("[CloudBridge] ListCloudProvidersTyped called")

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

	return providers, nil
}

// ListCloudProviders returns all available cloud providers
func (a *App) ListCloudProviders() FlagResult {
	providers, err := a.ListCloudProvidersTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list providers: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(providers)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal providers: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Found %d providers: %s", len(providers), string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) SetCloudProviderTyped(providerName string) (*CloudProviderInfo, error) {
	log.Printf("[CloudBridge] SetCloudProviderTyped called with: %s", providerName)

	if err := a.CloudManager.SetActiveProvider(providerName); err != nil {
		return nil, err
	}

	return a.GetCloudProviderTyped()
}

// SetCloudProvider sets the active cloud provider
func (a *App) SetCloudProvider(providerName string) FlagResult {
	info, err := a.SetCloudProviderTyped(providerName)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to set provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Successfully set active provider to: %s", providerName)
	data, err := json.Marshal(info)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) GetCloudProviderTyped() (*CloudProviderInfo, error) {
	log.Printf("[CloudBridge] GetCloudProviderTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	info := &CloudProviderInfo{
		Name:        provider.Name(),
		DisplayName: provider.DisplayName(),
	}
	return info, nil
}

// GetCloudProvider returns the current active provider
func (a *App) GetCloudProvider() FlagResult {
	info, err := a.GetCloudProviderTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(info)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal provider info: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Current provider: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) GetCloudConfigTyped() (*cloud.ProviderConfig, error) {
	log.Printf("[CloudBridge] GetCloudConfigTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	cfg, err := provider.LoadConfig()
	if err != nil {
		return nil, err
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

	return cfg, nil
}

// GetCloudConfig returns the persisted configuration for the active provider
func (a *App) GetCloudConfig() FlagResult {
	cfg, err := a.GetCloudConfigTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to load config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Loaded config for provider %s", cfg.Provider)
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) SaveCloudConfigTyped(cfg cloud.ProviderConfig) error {
	log.Printf("[CloudBridge] SaveCloudConfigTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return err
	}

	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	if cfg.Provider != provider.Name() {
		return fmt.Errorf("config provider mismatch with active provider")
	}

	if err := provider.ValidateConfig(&cfg); err != nil {
		return err
	}

	return provider.SaveConfig(&cfg)
}

// SaveCloudConfig persists configuration for the active provider
func (a *App) SaveCloudConfig(configJSON string) FlagResult {
	log.Printf("[CloudBridge] SaveCloudConfig called with payload length: %d", len(configJSON))

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse config JSON: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if err := a.SaveCloudConfigTyped(cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Config validation failed: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Config saved for provider %s (defaultRegion=%s, defaultPlan=%s)", cfg.Provider, cfg.DefaultRegion, cfg.DefaultPlan)
	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) ListCloudInstancesTyped() ([]cloud.Instance, error) {
	log.Printf("[CloudBridge] ListCloudInstancesTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	return provider.ListInstances(context.Background())
}

// ListCloudInstances returns all instances for the active provider
func (a *App) ListCloudInstances() FlagResult {
	instances, err := a.ListCloudInstancesTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instances)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d instances", len(instances))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) CreateCloudInstanceTyped(opts cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	log.Printf("[CloudBridge] CreateCloudInstanceTyped called (options redacted for security)")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	return provider.CreateInstance(context.Background(), &opts)
}

// CreateCloudInstance creates a new instance on the active provider
func (a *App) CreateCloudInstance(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateCloudInstance called (options redacted for security)")

	var opts cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse options: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	instance, err := a.CreateCloudInstanceTyped(opts)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to create instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instance)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Created instance %s", instance.ID)
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) DestroyCloudInstanceTyped(instanceID string) error {
	log.Printf("[CloudBridge] DestroyCloudInstanceTyped called for instance: %s", instanceID)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return err
	}

	return provider.DestroyInstance(context.Background(), instanceID)
}

// DestroyCloudInstance destroys an instance on the active provider
func (a *App) DestroyCloudInstance(instanceID string) FlagResult {
	if err := a.DestroyCloudInstanceTyped(instanceID); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to destroy instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Destroyed instance %s", instanceID)
	return FlagResult{Flag: true, Data: "Instance destroyed successfully"}
}

func (a *App) ListCloudRegionsTyped() ([]cloud.Region, error) {
	log.Printf("[CloudBridge] ListCloudRegionsTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	return provider.ListRegions(context.Background())
}

// ListCloudRegions returns all regions for the active provider
func (a *App) ListCloudRegions() FlagResult {
	regions, err := a.ListCloudRegionsTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(regions)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d regions", len(regions))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListCloudPlansTyped() ([]cloud.Plan, error) {
	log.Printf("[CloudBridge] ListCloudPlansTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	return provider.ListPlans(context.Background(), "")
}

// ListCloudPlans returns all plans for the active provider
func (a *App) ListCloudPlans() FlagResult {
	plans, err := a.ListCloudPlansTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d plans", len(plans))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListCloudAvailabilityTyped(region string) ([]string, error) {
	log.Printf("[CloudBridge] ListCloudAvailabilityTyped called for region: %s", region)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	return provider.ListAvailability(context.Background(), region)
}

// ListCloudAvailability returns plan availability for the active provider
func (a *App) ListCloudAvailability(region string) FlagResult {
	plans, err := a.ListCloudAvailabilityTyped(region)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d available plans for region %s", len(plans), region)
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
func (a *App) TestSSHConnectionTyped(extra map[string]string) (*sshprovider.ServerInfo, error) {
	log.Printf("[CloudBridge] TestSSHConnectionTyped called")

	provider, err := a.CloudManager.GetProvider("ssh")
	if err != nil {
		return nil, fmt.Errorf("SSH provider not registered: %w", err)
	}

	sshProvider, ok := provider.(*sshprovider.Provider)
	if !ok {
		return nil, fmt.Errorf("failed to get SSH provider instance")
	}

	return sshProvider.TestConnection(extra)
}

func (a *App) TestSSHConnection(configJSON string) FlagResult {
	log.Printf("[CloudBridge] TestSSHConnection called")

	var extra map[string]string
	if err := json.Unmarshal([]byte(configJSON), &extra); err != nil {
		return FlagResult{Flag: false, Data: "invalid config JSON: " + err.Error()}
	}

	info, err := a.TestSSHConnectionTyped(extra)
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
func (a *App) CreateMultipleCloudInstancesTyped(optsList []cloud.CreateInstanceOptions) ([]MultiDeployResult, error) {
	log.Printf("[CloudBridge] CreateMultipleCloudInstancesTyped called")

	if len(optsList) == 0 {
		return nil, fmt.Errorf("no instances to create")
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
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
	return results, nil
}

func (a *App) CreateMultipleCloudInstances(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateMultipleCloudInstances called")

	var optsList []cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &optsList); err != nil {
		return FlagResult{Flag: false, Data: "invalid options JSON: " + err.Error()}
	}

	results, err := a.CreateMultipleCloudInstancesTyped(optsList)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

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
