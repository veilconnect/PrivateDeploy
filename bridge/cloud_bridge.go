package bridge

import (
	"encoding/json"
	"log"
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
