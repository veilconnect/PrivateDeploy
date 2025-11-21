# 阶段2实施指南：regional reachability应对方案

**创建时间**: 2025-11-21
**当前进度**: 1/7 任务完成

---

## ✅ 已完成任务

### 任务1: 连通性自动检测后端API ✓

**实现文件**: `bridge/net.go`

**新增函数**:
```go
// TestTCPPort - 测试TCP端口是否开放
func TestTCPPort(ip string, port int, timeout int) bool

// TestConnectivity - 测试IP和端口的连通性
func (a *App) TestConnectivity(ip string, portsJSON string) FlagResult
```

**返回JSON格式**:
```json
{
  "ip": "192.0.2.1",
  "icmpReachable": false,
  "portsOpen": {
    "26248": true,
    "26250": true,
    "26251": false
  },
  "status": "icmp_blocked"  // reachable | icmp_blocked | blocked
}
```

**状态说明**:
- `reachable` 🟢: ICMP和端口都通，完全可用
- `icmp_blocked` 🟡: ICMP被屏蔽但端口开放，VPN可能仍可用
- `blocked` 🔴: 完全被regional reachability屏蔽

---

## 🚧 剩余任务实施指南

### 任务2: 连通性检测前端UI

**目标**: 在节点列表中显示连通性状态

**步骤1**: 添加前端API包装

文件: `frontend/src/bridge/app.ts`

```typescript
import type { ConnectivityResult } from '@/types/cloud'

export const TestConnectivity = async (ip: string, ports: number[]): Promise<ConnectivityResult> => {
  const portsJSON = JSON.stringify(ports)
  const { flag, data } = await App.TestConnectivity(ip, portsJSON)
  if (!flag) {
    throw new Error(data)
  }
  return JSON.parse(data) as ConnectivityResult
}
```

**步骤2**: 在CloudView中添加连通性检测

文件: `frontend/src/views/CloudView/index.vue`

在节点数据中添加connectivity字段：
```typescript
interface ManagedCloudNode extends CloudNode {
  statusText?: CloudNodeStatus
  connectivity?: ConnectivityResult
  connectivityTesting?: boolean
}
```

添加测试函数：
```typescript
const testNodeConnectivity = async (node: ManagedCloudNode) => {
  if (!node.ipv4) return

  node.connectivityTesting = true

  const ports = [
    node.ssPort,
    node.hysteriaPort,
    node.vlessPort,
    node.trojanPort
  ].filter(p => p && p > 0) as number[]

  try {
    const result = await TestConnectivity(node.ipv4, ports)
    node.connectivity = result
  } catch (error) {
    console.error('[CloudView] Connectivity test failed:', error)
  } finally {
    node.connectivityTesting = false
  }
}
```

**步骤3**: 在表格中显示连通性状态

```vue
<Column prop="connectivity" label="连通性" width="120">
  <template #default="{ row }">
    <div v-if="row.connectivityTesting">
      <Spinner size="small" /> 检测中...
    </div>
    <div v-else-if="row.connectivity">
      <Tag v-if="row.connectivity.status === 'reachable'" type="success">
        ✅ 畅通
      </Tag>
      <Tag v-else-if="row.connectivity.status === 'icmp_blocked'" type="warning">
        ⚠️ ICMP屏蔽
        <Tooltip content="端口可用，VPN可能仍然可用" />
      </Tag>
      <Tag v-else type="error">
        ❌ 完全屏蔽
      </Tag>
    </div>
    <Button v-else @click="testNodeConnectivity(row)" size="small">
      测试
    </Button>
  </template>
</Column>
```

**步骤4**: 自动测试新部署的节点

在`createInstance`成功后自动测试：
```typescript
const handleDeploy = async () => {
  // ... 部署节点

  // 等待节点就绪
  await new Promise(resolve => setTimeout(resolve, 30000))

  // 自动测试连通性
  const newNode = instances.value[0]
  if (newNode) {
    await testNodeConnectivity(newNode)

    // 如果被屏蔽，提示用户
    if (newNode.connectivity?.status === 'blocked') {
      const shouldRetry = await confirm({
        title: '节点不可用',
        content: 'IP被regional reachability屏蔽，是否自动轮换IP？',
      })

      if (shouldRetry) {
        await rotateIP(newNode)
      }
    }
  }
}
```

---

### 任务3: 智能IP轮换功能

**目标**: 一键删除旧节点并重新部署到同区域获得新IP

**实现**: `frontend/src/stores/cloud.ts`

```typescript
/**
 * 轮换节点IP - 删除旧节点并在同区域重新部署
 */
const rotateIP = async (node: ManagedCloudNode) => {
  const { region, plan, label } = node

  if (!region || !plan) {
    throw new Error('Missing region or plan information')
  }

  try {
    // 1. 删除旧节点
    logInfo(`[CloudStore] Rotating IP for node: ${label}`)
    await destroyInstance(node.instanceId)

    // 2. 生成新标签
    const newLabel = `${region}-${Date.now()}`

    // 3. 部署新节点
    const newNode = await createInstance({ label: newLabel, region, plan })

    // 4. 等待节点就绪
    await new Promise(resolve => setTimeout(resolve, 60000))

    // 5. 测试连通性
    if (newNode.ipv4) {
      const ports = [newNode.ssPort, newNode.vlessPort, newNode.trojanPort].filter(Boolean) as number[]
      const connectivity = await TestConnectivity(newNode.ipv4, ports)

      if (connectivity.status === 'reachable') {
        message.success('IP轮换成功！新节点已可用')
        return newNode
      } else if (connectivity.status === 'icmp_blocked') {
        message.warn('新IP的ICMP被屏蔽，但端口可用，VPN可能仍然可用')
        return newNode
      } else {
        message.error('新IP仍被屏蔽，建议更换区域')
        return null
      }
    }
  } catch (error) {
    logError('[CloudStore] IP rotation failed:', error)
    throw error
  }
}
```

**UI集成**: 在节点操作菜单中添加"轮换IP"按钮

```vue
<Dropdown>
  <DropdownItem @click="handleUseNode(row)">选用节点</DropdownItem>
  <DropdownItem @click="handleRotateIP(row)">轮换IP</DropdownItem>
  <DropdownItem @click="handleDeleteNode(row)" danger>删除节点</DropdownItem>
</Dropdown>
```

---

### 任务4: 区域可达性风险标注

**目标**: 在区域选择器中标注可达性风险等级

**数据源**: 基于`REGION-RECOMMENDATIONS.md`的真实测试数据

**实现**: `frontend/src/views/CloudView/index.vue`

```typescript
// 可达性风险评级
const reachabilityRiskRating: Record<string, { level: number; label: string; emoji: string }> = {
  // 低风险（推荐）
  'bom': { level: 1, label: '低风险', emoji: '🟢' },
  'fra': { level: 1, label: '低风险', emoji: '🟢' },
  'yto': { level: 1, label: '低风险', emoji: '🟢' },
  'lhr': { level: 1, label: '低风险', emoji: '🟢' },

  // 中等风险
  'lax': { level: 2, label: '中等风险', emoji: '🟡' },
  'sjc': { level: 2, label: '中等风险', emoji: '🟡' },

  // 高风险
  'sgp': { level: 3, label: '高风险', emoji: '🟠' },
  'nrt': { level: 4, label: '极高风险', emoji: '🔴' },
  'icn': { level: 4, label: '极高风险', emoji: '🔴' },
}

const getReachabilityRisk = (regionCode: string) => {
  return reachabilityRiskRating[regionCode] || { level: 2, label: '未知', emoji: '⚪' }
}
```

**UI显示**: 区域选择器增强

```vue
<Select v-model="form.region">
  <OptionGroup label="🌟 推荐区域（低延迟+regional reachability友好）">
    <Option v-for="region in recommendedRegions" :key="region.id" :value="region.id">
      {{ getReachabilityRisk(region.id).emoji }} {{ region.city }} · {{ latencyMap[region.id] || '-' }}ms
      <Tag type="success" size="small">{{ getReachabilityRisk(region.id).label }}</Tag>
    </Option>
  </OptionGroup>

  <OptionGroup label="⚠️ 可用但需注意">
    <Option v-for="region in mediumRiskRegions" :key="region.id" :value="region.id">
      {{ getReachabilityRisk(region.id).emoji }} {{ region.city }} · {{ latencyMap[region.id] || '-' }}ms
    </Option>
  </OptionGroup>

  <OptionGroup label="❌ 不推荐使用">
    <Option v-for="region in highRiskRegions" :key="region.id" :value="region.id" disabled>
      {{ getReachabilityRisk(region.id).emoji }} {{ region.city }} - {{ getReachabilityRisk(region.id).label }}
    </Option>
  </OptionGroup>
</Select>
```

**国际化支持**: 添加翻译

`frontend/src/lang/locale/zh.ts`:
```typescript
cloud: {
  gfw: {
    lowRisk: '低风险',
    mediumRisk: '中等风险',
    highRisk: '高风险',
    veryHighRisk: '极高风险',
    unknown: '未知',
    recommended: '推荐',
    caution: '需注意',
    notRecommended: '不推荐',
  }
}
```

---

### 任务5: 增强节点列表显示

**目标**: 在节点列表中增加延迟和连通性列

**当前列**:
```
名称 | 区域 | 套餐 | IP地址 | 协议 | 状态 | 创建时间 | 操作
```

**优化后**:
```
名称 | 区域 | 延迟 | 连通性 | 协议 | 状态 | 操作
```

**实现**: 修改表格列定义

```typescript
const columns = [
  { title: 'cloud.table.label', key: 'label', width: '15%' },
  { title: 'cloud.table.region', key: 'region', width: '12%' },
  { title: 'cloud.table.latency', key: 'latency', width: '10%' },       // 新增
  { title: 'cloud.table.connectivity', key: 'connectivity', width: '12%' },  // 新增
  { title: 'cloud.table.protocols', key: 'protocols', width: '20%' },
  { title: 'cloud.table.status', key: 'status', width: '12%' },
  { title: 'cloud.table.actions', key: 'actions', width: '19%' },
]
```

**延迟列**:
```vue
<Column prop="latency" label="延迟">
  <template #default="{ row }">
    <span v-if="row.latency" :style="{ color: getLatencyColor(row.latency) }">
      {{ row.latency }}ms
    </span>
    <Button v-else @click="testLatency(row)" size="small">测试</Button>
  </template>
</Column>
```

**连通性列**: (见任务2)

---

### 任务6: 优化错误提示

**目标**: 将技术性错误转换为用户友好的提示

**实现**: `frontend/src/composables/useErrorHandler.ts`

```typescript
export function useErrorHandler() {
  const { t } = useI18n()

  const errorMessages: Record<string, string> = {
    // API错误
    'api key': t('cloud.errors.invalidApiKey'),
    'not authorized': t('cloud.errors.unauthorized'),
    'rate limit': t('cloud.errors.rateLimit'),

    // 部署错误
    'plan.*not available': t('cloud.errors.planUnavailable'),
    'insufficient funds': t('cloud.errors.insufficientFunds'),
    'region.*not available': t('cloud.errors.regionUnavailable'),

    // 网络错误
    'timeout': t('cloud.errors.timeout'),
    'network error': t('cloud.errors.networkError'),

    // regional reachability相关
    'address already in use': t('cloud.errors.portConflict'),
    'connection refused': t('cloud.errors.connectionRefused'),
  }

  const translateError = (error: Error): string => {
    const errorMsg = error.message.toLowerCase()

    for (const [pattern, message] of Object.entries(errorMessages)) {
      if (new RegExp(pattern, 'i').test(errorMsg)) {
        return message
      }
    }

    return t('cloud.errors.unknown', { error: error.message })
  }

  const handleError = (error: Error, context: string) => {
    const userMessage = translateError(error)
    message.error(userMessage)
    console.error(`[${context}]`, error)
  }

  return { translateError, handleError }
}
```

**翻译文件**: `frontend/src/lang/locale/zh.ts`

```typescript
cloud: {
  errors: {
    invalidApiKey: 'API密钥无效，请检查配置',
    unauthorized: '未授权访问，请检查API密钥权限',
    rateLimit: '操作过于频繁，请稍后再试',
    planUnavailable: '所选套餐在该区域不可用，请选择其他套餐',
    insufficientFunds: '账户余额不足，请充值后重试',
    regionUnavailable: '该区域暂不可用，请选择其他区域',
    timeout: '操作超时，请检查网络连接',
    networkError: '网络错误，请稍后重试',
    portConflict: '端口被占用，正在自动重新分配...',
    connectionRefused: '连接被拒绝，节点可能被regional reachability屏蔽',
    unknown: '操作失败：{error}',
  }
}
```

---

### 任务7: 添加测试和文档

**单元测试**: `bridge/net_test.go`

```go
package bridge

import (
	"testing"
	"time"
)

func TestTestTCPPort(t *testing.T) {
	tests := []struct {
		name    string
		ip      string
		port    int
		timeout int
		want    bool
	}{
		{
			name:    "Google DNS port 53",
			ip:      "8.8.8.8",
			port:    53,
			timeout: 3000,
			want:    true,
		},
		{
			name:    "Invalid port",
			ip:      "8.8.8.8",
			port:    99999,
			timeout: 1000,
			want:    false,
		},
		{
			name:    "Closed port",
			ip:      "127.0.0.1",
			port:    9999,
			timeout: 1000,
			want:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := TestTCPPort(tt.ip, tt.port, tt.timeout)
			if got != tt.want {
				t.Errorf("TestTCPPort() = %v, want %v", got, tt.want)
			}
		})
	}
}
```

**文档**: `docs/regional reachability_DETECTION.md`

```markdown
# regional reachability检测与应对指南

## 功能概述

PrivateDeploy 提供完整的regional reachability（防火长城）检测和应对方案。

### 1. 连通性自动检测

部署节点后，系统会自动检测：
- ✅ ICMP连通性（ping）
- ✅ TCP端口开放状态
- ✅ 综合连通性评估

### 2. 智能IP轮换

当检测到IP被屏蔽时，一键轮换：
1. 自动删除旧节点
2. 在同区域重新部署
3. 获得新的IP地址
4. 自动测试新IP

### 3. 区域风险评级

基于真实测试数据的可达性风险评级：
- 🟢 低风险：孟买、法兰克福、多伦多、伦敦
- 🟡 中等风险：洛杉矶、硅谷
- 🟠 高风险：新加坡
- 🔴 极高风险：东京、首尔

## 使用指南

### 部署新节点

1. 选择低风险区域（推荐：孟买、法兰克福）
2. 点击"部署节点"
3. 等待2-5分钟完成部署
4. 系统自动测试连通性
5. 根据检测结果决策：
   - 🟢 畅通：直接使用
   - 🟡 ICMP屏蔽：尝试连接VPN
   - 🔴 完全屏蔽：轮换IP或更换区域

### IP轮换流程

当节点被屏蔽时：
1. 点击节点右侧的"轮换IP"按钮
2. 确认操作
3. 系统自动完成轮换（约3-5分钟）
4. 检查新节点连通性

### 最佳实践

1. **优先选择低风险区域**
   - 避开东京、首尔、新加坡
   - 推荐：孟买（延迟最低）、法兰克福（稳定性最佳）

2. **定期检查节点状态**
   - 每周测试一次连通性
   - regional reachability黑名单动态更新，今天可用的IP明天可能被屏蔽

3. **保持多节点冗余**
   - 在2-3个不同区域部署节点
   - 一个被屏蔽时立即切换到备用节点

4. **使用伪装协议**
   - 优先使用Trojan或VLESS-Reality
   - 避免使用明文Shadowsocks

## 故障排查

### 问题1：新部署的节点无法连接

**检查步骤**：
1. 查看连通性状态
2. 如果显示"ICMP屏蔽"，尝试直接连接VPN
3. 如果显示"完全屏蔽"，轮换IP或更换区域

### 问题2：IP轮换后仍然不可用

**解决方案**：
- 该区域IP池可能被大量屏蔽
- 建议更换到低风险区域
- 优先选择：孟买 > 法兰克福 > 多伦多

### 问题3：所有节点都被屏蔽

**应急方案**：
1. 删除所有高风险区域节点
2. 在孟买/法兰克福重新部署
3. 重复轮换IP直到获得可用IP
4. 考虑更换云服务商（Vultr → DigitalOcean）
```

---

## 📊 实施优先级建议

### 高优先级（必须实现）
- ✅ 任务1: 连通性检测后端API（已完成）
- 任务2: 连通性检测前端UI
- 任务3: 智能IP轮换功能
- 任务4: 区域可达性风险标注

### 中优先级（建议实现）
- 任务5: 增强节点列表显示
- 任务6: 优化错误提示

### 低优先级（可选）
- 任务7: 添加测试和文档

---

## 🚀 下一步行动

### 选项A: 快速实现核心功能（2-3小时）
仅实现任务2-4，提供基本的regional reachability应对能力

### 选项B: 完整实现（4-6小时）
实现所有7个任务，提供完善的regional reachability应对方案

### 选项C: 分阶段实施
- 本周：任务2-3（连通性检测+IP轮换）
- 下周：任务4-5（可达性风险标注+列表增强）
- 后续：任务6-7（错误提示+测试文档）

---

**文档版本**: 1.0
**最后更新**: 2025-11-21
**负责人**: AI Assistant
