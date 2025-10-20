# 多云架构实施指南

## 当前进度

✅ **已完成**：
1. 云服务商抽象接口定义 (`bridge/cloud/interface.go`)
2. 错误定义 (`bridge/cloud/errors.go`)
3. Provider注册器和管理器 (`bridge/cloud/registry.go`)

## 架构概览

```
bridge/cloud/
├── interface.go          # CloudProvider接口定义
├── errors.go            # 错误定义
├── registry.go          # Provider注册和管理
├── manager.go           # 统一管理器（已包含在registry.go）
└── providers/
    ├── vultr/
    │   ├── provider.go      # Vultr实现入口
    │   ├── api.go          # API调用封装
    │   ├── config.go       # 配置管理
    │   ├── deploy.go       # 部署脚本生成
    │   └── types.go        # Vultr特定类型
    ├── digitalocean/
    │   ├── provider.go
    │   ├── api.go
    │   ├── config.go
    │   ├── deploy.go
    │   └── types.go
    └── ... (其他provider)
```

## 迁移步骤

### 步骤1：Vultr Provider重构

#### 1.1 创建 provider.go

```go
package vultr

import (
	"context"
	"veildeploy/bridge/cloud"
)

// Provider implements cloud.CloudProvider for Vultr
type Provider struct {
	config *cloud.ProviderConfig
	// 复用现有vultr.go中的缓存机制
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

// ListRegions 实现接口
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	// 调用现有的listVultrRegions逻辑
	// 转换为统一的cloud.Region格式
}

// ... 其他接口实现
```

#### 1.2 迁移现有代码

**从 `bridge/vultr.go` 提取到模块化文件**：

- `api.go`:
  - `vultrRequest()`
  - `parseVultrResponse()`
  - API调用辅助函数

- `config.go`:
  - `loadVultrConfig()`
  - `saveVultrConfig()`
  - 配置相关逻辑

- `deploy.go`:
  - `generateInitScript()`
  - `generatePasswordHash()`
  - `generateRealityKeyPair()`
  - 所有部署脚本生成函数

- `types.go`:
  - Vultr API响应结构体
  - 内部数据结构

### 步骤2：更新 bridge/app.go

在App结构体中添加CloudManager：

```go
type App struct {
	// ... 现有字段
	CloudManager *cloud.Manager
}

func CreateApp(assets fs.FS) *App {
	app := &App{
		// ... 现有初始化
		CloudManager: cloud.NewManager(context.Background()),
	}

	// 注册Vultr provider
	vultrProvider := vultr.New(nil) // 配置后续加载
	cloud.Register("vultr", vultrProvider)

	// 设置默认provider
	app.CloudManager.SetActiveProvider("vultr")

	return app
}
```

### 步骤3：暴露新的Wails方法

```go
// ListCloudProviders returns all available cloud providers
func (a *App) ListCloudProviders() FlagResult {
	providers := a.CloudManager.ListProviders()
	data, _ := json.Marshal(providers)
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
	if a.CloudManager.activeProvider == "" {
		return FlagResult{Flag: false, Data: "no active provider"}
	}
	return FlagResult{Flag: true, Data: a.CloudManager.activeProvider}
}

// 保持现有API兼容，但内部使用Manager
func (a *App) ListVultrInstances() FlagResult {
	// 通过Manager调用
	instances, err := a.CloudManager.ListInstances()
	// ... 转换并返回
}
```

### 步骤4：前端适配

#### 4.1 更新类型定义

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
  provider: CloudProvider  // 新增
  instanceId: string
  label: string
  status: string
  region: string
  plan: string
  osId: number
  ipv4: string
  ipv6?: string
  // ... 其他字段保持不变
}
```

#### 4.2 更新Store

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
      await loadConfig() // 重新加载配置
      await refreshInstances() // 刷新实例列表
    }
  }

  return {
    // ... 现有返回
    availableProviders,
    currentProvider,
    loadProviders,
    switchProvider,
  }
})
```

#### 4.3 UI更新

```vue
<!-- frontend/src/views/CloudView/index.vue -->
<template>
  <div class="cloud-view">
    <!-- Provider选择器 -->
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

    <!-- Vultr配置 (provider==='vultr'时显示) -->
    <Card v-if="cloudStore.currentProvider === 'vultr'" :title="t('cloud.vultrConfig')">
      <!-- 现有Vultr配置UI -->
    </Card>

    <!-- DigitalOcean配置 (provider==='digitalocean'时显示) -->
    <Card v-if="cloudStore.currentProvider === 'digitalocean'" :title="t('cloud.doConfig')">
      <!-- DigitalOcean API配置 -->
    </Card>

    <!-- 其他内容保持不变 -->
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

## DigitalOcean Provider实现示例

```go
// bridge/cloud/providers/digitalocean/provider.go
package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"veildeploy/bridge/cloud"
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

// ... 其他接口实现
```

## 数据迁移

### 配置文件格式

**旧格式** (`data/vultr-config.json`):
```json
{
  "apiKey": "xxx",
  "defaultRegion": "nrt",
  "defaultPlan": "vc2-1c-1gb"
}
```

**新格式** (`data/cloud-config.json`):
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

### 实例ID格式

**新格式**: `cloud-{provider}-{uuid}`

示例:
- `cloud-vultr-0429965d-420b-48da-9653-85ad47278ef9`
- `cloud-do-a1b2c3d4-e5f6-7890-abcd-ef1234567890`

### 节点记录存储

**文件名**: `data/cloud-nodes.json`

```json
{
  "cloud-vultr-xxx": {
    "provider": "vultr",
    "plan": "vc2-1c-1gb",
    // ... Vultr特定字段
  },
  "cloud-do-yyy": {
    "provider": "digitalocean",
    "plan": "s-1vcpu-1gb",
    // ... DigitalOcean特定字段
  }
}
```

## 测试计划

### 单元测试

```go
// bridge/cloud/providers/vultr/provider_test.go
func TestVultrProvider(t *testing.T) {
	config := &cloud.ProviderConfig{
		Provider: "vultr",
		APIKey:   "test-key",
	}

	provider := New(config)

	// 测试接口实现
	assert.Equal(t, "vultr", provider.Name())
	assert.Equal(t, "Vultr", provider.DisplayName())
}
```

### 集成测试

1. Provider注册测试
2. 多Provider切换测试
3. 配置持久化测试
4. API调用测试（使用mock）

## 下一步行动

### 立即执行（1-2天）
1. ✅ 创建基础架构（已完成）
2. 🔄 创建Vultr provider骨架
3. 🔄 迁移核心功能到新架构
4. 🔄 更新前端Bridge绑定

### 短期（3-5天）
1. 完成Vultr provider迁移
2. 实现DigitalOcean provider
3. 更新前端UI支持provider选择
4. 数据迁移脚本

### 中期（1-2周）
1. 添加更多provider (Linode, Hetzner)
2. 性能优化
3. 完善文档
4. 用户测试

## 回滚计划

如果新架构出现问题，可以：
1. 保留旧的 `vultr.go` 文件
2. 通过功能开关控制使用新/旧架构
3. 逐步迁移用户数据

## 技术债务

- [ ] Vultr provider完全迁移
- [ ] 移除bridge/vultr.go
- [ ] 统一错误处理
- [ ] 添加日志系统
- [ ] 性能监控

---

**当前状态**: 基础架构已搭建完成 ✅
**下一步**: 创建Vultr provider实现
