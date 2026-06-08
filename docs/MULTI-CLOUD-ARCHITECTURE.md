# Multi-Cloud Architecture Implementation Guide

**English** | [中文](MULTI-CLOUD-ARCHITECTURE.zh-CN.md)

## Current Progress

✅ **Completed**:
1. Cloud provider abstraction interface definition (`bridge/cloud/interface.go`)
2. Error definitions (`bridge/cloud/errors.go`)
3. Provider registry and manager (`bridge/cloud/registry.go`)

## Architecture Overview

```
bridge/cloud/
├── interface.go          # CloudProvider interface definition
├── errors.go            # Error definitions
├── registry.go          # Provider registration and management
├── manager.go           # Unified manager (already included in registry.go)
└── providers/
    ├── vultr/
    │   ├── provider.go      # Vultr implementation entry point
    │   ├── api.go          # API call wrapper
    │   ├── config.go       # Configuration management
    │   ├── deploy.go       # Deployment script generation
    │   └── types.go        # Vultr-specific types
    ├── digitalocean/
    │   ├── provider.go
    │   ├── api.go
    │   ├── config.go
    │   ├── deploy.go
    │   └── types.go
    └── ... (other providers)
```

## Migration Steps

### Step 1: Vultr Provider Refactoring

#### 1.1 Create provider.go

```go
package vultr

import (
	"context"
	"privatedeploy/bridge/cloud"
)

// Provider implements cloud.CloudProvider for Vultr
type Provider struct {
	config *cloud.ProviderConfig
	// Reuse the caching mechanism in the existing vultr.go
}

// New creates a new Vultr provider
func New(config *cloud.ProviderConfig) *Provider {
	return &Provider{config: config}
}

// Name returns the provider name
func (p *Provider) Name() string {
	return "vultr"
}

// DisplayName returns the display name
func (p *Provider) DisplayName() string {
	return "Vultr"
}

// ListRegions implements the interface
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	// Call the existing listVultrRegions logic
	// Convert to the unified cloud.Region format
}

// ... other interface implementations
```

#### 1.2 Migrate Existing Code

**Extract from `bridge/vultr.go` into modular files**:

- `api.go`:
  - `vultrRequest()`
  - `parseVultrResponse()`
  - API call helper functions

- `config.go`:
  - `loadVultrConfig()`
  - `saveVultrConfig()`
  - Configuration-related logic

- `deploy.go`:
  - `generateInitScript()`
  - `generatePasswordHash()`
  - `generateRealityKeyPair()`
  - All deployment script generation functions

- `types.go`:
  - Vultr API response structs
  - Internal data structures

### Step 2: Update bridge/app.go

Add CloudManager to the App struct:

```go
type App struct {
	// ... existing fields
	CloudManager *cloud.Manager
}

func CreateApp(assets fs.FS) *App {
	registry := cloud.NewRegistry()

	// Register the Vultr provider
	vultrProvider := vultr.New(nil) // configuration loaded later
	registry.Register("vultr", vultrProvider)

	app := &App{
		// ... existing initialization
		CloudManager: cloud.NewManager(context.Background(), registry),
	}

	// Set the default provider
	app.CloudManager.SetActiveProvider("vultr")

	return app
}
```

### Step 3: Expose New Wails Methods

```go
// ListCloudProviders returns all available cloud providers
func (a *App) ListCloudProviders() FlagResult {
	providerNames := a.CloudManager.ListProviders()
	data, _ := json.Marshal(providerNames)
	return FlagResult{Flag: true, Data: string(data)}
}

// SetCloudProvider sets the active cloud provider
func (a *App) SetCloudProvider(providerName string) FlagResult {
	err := a.CloudManager.SetActiveProvider(providerName)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: ""}
}

// GetCloudProvider returns the current active provider
func (a *App) GetCloudProvider() FlagResult {
	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	info := struct {
		Name        string `json:"name"`
		DisplayName string `json:"displayName"`
	}{
		Name:        provider.Name(),
		DisplayName: provider.DisplayName(),
	}
	data, _ := json.Marshal(info)
	return FlagResult{Flag: true, Data: string(data)}
}

// Keep existing API compatibility, but use the Manager internally
func (a *App) ListVultrInstances() FlagResult {
	// Call through the Manager
	instances, err := a.CloudManager.ListInstances()
	// ... convert and return
}
```

### Step 4: Frontend Adaptation

#### 4.1 Update Type Definitions

```typescript
// frontend/src/types/cloud.d.ts
export type CloudProvider = 'vultr' | 'digitalocean' | 'linode' | 'aws' | 'hetzner'

export interface CloudConfig {
  provider: CloudProvider
  apiKey: string
  defaultRegion?: string
  defaultPlan?: string
  extra?: Record<string, string>
}

export interface CloudNode {
  provider: CloudProvider  // newly added
  instanceId: string
  label: string
  status: string
  region: string
  plan: string
  osId: number
  ipv4: string
  ipv6?: string
  // ... other fields remain unchanged
}
```

#### 4.2 Update Store

```typescript
// frontend/src/stores/cloud.ts
import { ListCloudProviders, SetCloudProvider, GetCloudProvider } from '@/bridge'

export const useCloudStore = defineStore('cloud', () => {
  const availableProviders = ref<CloudProvider[]>([])
  const currentProvider = ref<CloudProvider>('vultr')

  const loadProviders = async () => {
    const res = await ListCloudProviders()
    if (res.flag) {
      availableProviders.value = JSON.parse(res.data)
    }
  }

  const switchProvider = async (provider: CloudProvider) => {
    const res = await SetCloudProvider(provider)
    if (res.flag) {
      currentProvider.value = provider
      await loadConfig() // reload configuration
      await refreshInstances() // refresh the instance list
    }
  }

  return {
    // ... existing returns
    availableProviders,
    currentProvider,
    loadProviders,
    switchProvider,
  }
})
```

#### 4.3 UI Update

```vue
<!-- frontend/src/views/CloudView/index.vue -->
<template>
  <div class="cloud-view">
    <!-- Provider selector -->
    <Card class="provider-selector">
      <div class="flex items-center gap-8">
        <span>{{ t('cloud.provider') }}:</span>
        <Select
          v-model="cloudStore.currentProvider"
          @change="cloudStore.switchProvider"
          :options="providerOptions"
        />
      </div>
    </Card>

    <!-- Vultr configuration (shown when provider==='vultr') -->
    <Card v-if="cloudStore.currentProvider === 'vultr'" :title="t('cloud.vultrConfig')">
      <!-- Existing Vultr configuration UI -->
    </Card>

    <!-- DigitalOcean configuration (shown when provider==='digitalocean') -->
    <Card v-if="cloudStore.currentProvider === 'digitalocean'" :title="t('cloud.doConfig')">
      <!-- DigitalOcean API configuration -->
    </Card>

    <!-- Other content remains unchanged -->
  </div>
</template>

<script setup lang="ts">
const providerOptions = computed(() =>
  cloudStore.availableProviders.map(p => ({
    label: p.charAt(0).toUpperCase() + p.slice(1),
    value: p
  }))
)
</script>
```

## DigitalOcean Provider Implementation Example

```go
// bridge/cloud/providers/digitalocean/provider.go
package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"privatedeploy/bridge/cloud"
)

const baseURL = "https://api.digitalocean.com/v2"

type Provider struct {
	config *cloud.ProviderConfig
	client *http.Client
}

func New(config *cloud.ProviderConfig) *Provider {
	return &Provider{
		config: config,
		client: &http.Client{},
	}
}

func (p *Provider) Name() string {
	return "digitalocean"
}

func (p *Provider) DisplayName() string {
	return "DigitalOcean"
}

func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", baseURL+"/regions", nil)
	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Regions []struct {
			Slug      string   `json:"slug"`
			Name      string   `json:"name"`
			Available bool     `json:"available"`
		} `json:"regions"`
	}

	json.NewDecoder(resp.Body).Decode(&result)

	regions := make([]cloud.Region, 0)
	for _, r := range result.Regions {
		if !r.Available {
			continue
		}
		regions = append(regions, cloud.Region{
			ID:      r.Slug,
			City:    r.Name,
			Country: parseCountry(r.Name),
		})
	}

	return regions, nil
}

// ... other interface implementations
```

## Data Migration

### Configuration File Format

**Old format** (`data/vultr-config.json`):
```json
{
  "apiKey": "xxx",
  "defaultRegion": "nrt",
  "defaultPlan": "vc2-1c-1gb"
}
```

**New format** (`data/cloud-config.json`):
```json
{
  "activeProvider": "vultr",
  "providers": {
    "vultr": {
      "apiKey": "xxx",
      "defaultRegion": "nrt",
      "defaultPlan": "vc2-1c-1gb"
    },
    "digitalocean": {
      "apiKey": "yyy",
      "defaultRegion": "sgp1",
      "defaultPlan": "s-1vcpu-1gb"
    }
  }
}
```

### Instance ID Format

**New format**: `cloud-{provider}-{uuid}`

Examples:
- `cloud-vultr-<instance-id>`
- `cloud-do-a1b2c3d4-e5f6-7890-abcd-ef1234567890`

### Node Record Storage

**File name**: `data/cloud-nodes.json`

```json
{
  "cloud-vultr-xxx": {
    "provider": "vultr",
    "plan": "vc2-1c-1gb",
    // ... Vultr-specific fields
  },
  "cloud-do-yyy": {
    "provider": "digitalocean",
    "plan": "s-1vcpu-1gb",
    // ... DigitalOcean-specific fields
  }
}
```

## Test Plan

### Unit Tests

```go
// bridge/cloud/providers/vultr/provider_test.go
func TestVultrProvider(t *testing.T) {
	config := &cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "test-key",
	}

	provider := New(config)

	// Test interface implementation
	assert.Equal(t, "vultr", provider.Name())
	assert.Equal(t, "Vultr", provider.DisplayName())
}
```

### Integration Tests

1. Provider registration test
2. Multi-provider switching test
3. Configuration persistence test
4. API call test (using mock)

## Next Steps

### Immediate (1-2 days)
1. ✅ Create the base architecture (completed)
2. 🔄 Create the Vultr provider skeleton
3. 🔄 Migrate core functionality to the new architecture
4. 🔄 Update the frontend Bridge bindings

### Short-term (3-5 days)
1. Complete the Vultr provider migration
2. Implement the DigitalOcean provider
3. Update the frontend UI to support provider selection
4. Data migration script

### Mid-term (1-2 weeks)
1. Add more providers (Linode, Hetzner)
2. Performance optimization
3. Improve documentation
4. User testing

## Rollback Plan

If issues arise with the new architecture, you can:
1. Keep the old `vultr.go` file
2. Control whether to use the new/old architecture via a feature flag
3. Migrate user data gradually

## Technical Debt

- [ ] Fully migrate the Vultr provider
- [ ] Remove bridge/vultr.go
- [ ] Unify error handling
- [ ] Add a logging system
- [ ] Performance monitoring

---

**Current status**: Base architecture has been set up ✅
**Next step**: Create the Vultr provider implementation
