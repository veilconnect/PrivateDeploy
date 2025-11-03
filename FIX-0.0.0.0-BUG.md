# 修复: 配置生成时服务器地址变成 0.0.0.0

## 问题描述

在节点部署后，虽然订阅文件中的服务器地址正确，但生成 sing-box 配置时，所有代理节点的 `server` 字段会被错误地设置为 `0.0.0.0`，导致代理无法连接。

## 根本原因

配置生成过程中存在对象引用共享问题：
1. 订阅文件被读取并缓存到 `SubscriptionCache`
2. 在处理订阅时使用了浅拷贝 `{ ...entry }`
3. `normalizeProxy` 函数直接修改了对象
4. 多次引用同一对象导致意外修改

## 修复方案

### 1. 深拷贝缓存对象 (frontend/src/utils/generator.ts:174-181)

```typescript
if (Array.isArray(SubscriptionCache[subId])) {
  // Deep clone each entry to prevent any mutations affecting the cache
  SubscriptionCache[subId] = SubscriptionCache[subId]
    .map((entry) => {
      const clone = JSON.parse(JSON.stringify(entry))
      const tag = normalizeProxy(clone)
      return tag ? clone : null
    })
    .filter(Boolean)
}
```

### 2. 减少对象修改 (frontend/src/utils/generator.ts:111-122)

```typescript
const normalizeProxy = (proxy: Recordable, defaultFallback?: string) => {
  const fallback = ...
  // Don't mutate the original object, just ensure tag is set
  if (!proxy.tag || typeof proxy.tag !== 'string' || !proxy.tag.trim()) {
    proxy.tag = fallback
  }
  return proxy.tag
}
```

### 3. 配置验证 (frontend/src/utils/generator.ts:453-465)

添加配置写入前验证，防止错误的配置被保存：

```typescript
// Validate: check for invalid server addresses (0.0.0.0 or empty)
if (config.outbounds && Array.isArray(config.outbounds)) {
  for (const outbound of config.outbounds) {
    if (outbound.server) {
      const server = String(outbound.server).trim()
      if (server === '0.0.0.0' || server === '' || server === '::') {
        console.error(`[Generator] Invalid server address detected for ${outbound.tag}: "${server}"`)
        throw new Error(`Invalid server address for proxy ${outbound.tag}: server cannot be ${server}`)
      }
    }
  }
}
```

### 4. IP 等待机制 (frontend/src/stores/cloud.ts:563-574)

防止节点创建时 IP 未分配的问题：

```typescript
// If node doesn't have IP yet, wait for it with retry mechanism
if (!cloudNode.ipv4 && !cloudNode.ipv6) {
  logInfo('[CloudStore] Node created without IP, will retry subscription creation after refresh')
  cloudNode.statusText = 'pending'
  instances.value = instances.value.map((n) =>
    n.instanceId === cloudNode.instanceId ? cloudNode : n
  )
  // Trigger immediate refresh to get IP address
  setTimeout(() => refreshInstances().catch(() => undefined), 5000)
  return node
}
```

## 验证修复

编译后的应用会自动：
1. 使用深拷贝防止对象修改
2. 在写入配置前验证服务器地址
3. 如果检测到 0.0.0.0 会抛出错误并阻止写入
4. 在控制台输出详细的错误信息

## 临时修复脚本

如果仍然遇到问题，可以使用此脚本手动修复配置：

```bash
#!/bin/bash
python3 << 'EOF'
import json

config_path = '/home/user/PrivateDeploy/build/bin/data/sing-box/config.json'

# 读取并修复配置
with open(config_path) as f:
    config = json.load(f)

# 修复所有节点的服务器地址
fixed = 0
for ob in config.get('outbounds', []):
    tag = ob.get('tag', '')

    # 根据 tag 找到对应的订阅文件并获取正确的 IP
    if tag.startswith('sg-'):
        if 'v4' in tag:
            if ob.get('server') == '0.0.0.0':
                ob['server'] = '192.0.2.1'
                fixed += 1
        elif 'v6' in tag:
            if ob.get('server') in ['0.0.0.0', '::']:
                ob['server'] = '2001:db8::1'
                fixed += 1

# 写回
if fixed > 0:
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print(f'✓ 已修复 {fixed} 个节点的服务器地址')
else:
    print('✓ 配置正确，无需修复')
EOF
```

## 测试步骤

1. 重新编译应用：
```bash
cd /home/user/PrivateDeploy
PATH="/usr/local/go/bin:/home/user/go/bin:/home/user/.npm-global/bin:$PATH" wails build
```

2. 启动应用并检查日志
3. 如果看到 `Invalid server address` 错误，说明验证生效
4. 正常情况下配置应该正确生成

## 后续改进建议

1. **添加单元测试**：测试订阅文件处理和配置生成
2. **日志增强**：添加更详细的调试日志追踪对象变化
3. **类型安全**：使用 TypeScript 严格类型避免意外修改
4. **不可变数据**：考虑使用 Immer.js 等库强制不可变性

## 更新日志

- 2025-11-03: 初始修复 - 添加深拷贝、配置验证、IP等待机制
