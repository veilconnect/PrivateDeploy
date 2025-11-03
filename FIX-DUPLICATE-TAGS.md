# 修复: 重复的 Outbound Tag 错误

**日期:** 2025-11-03
**状态:** ✅ 已修复
**相关问题:** 在修复 0.0.0.0 bug 时引入

## 问题描述

在运行修复 0.0.0.0 bug 后的版本时，sing-box 启动失败并报错：

```
FATAL[0000] decode config at /home/user/PrivateDeploy/build/bin/data/sing-box/config.json:
duplicate outbound/endpoint tag: sg-ss-v4
```

**影响范围：**
- 所有 8 个代理标签都重复 4 次
- sing-box 无法启动
- 配置文件包含 32 个 outbounds（预期只有 8 个）

**重复标签列表：**
```
sg-ss-v4         - 出现 4 次
sg-ss-v6         - 出现 4 次
sg-hysteria2-v4  - 出现 4 次
sg-hysteria2-v6  - 出现 4 次
sg-vless-v4      - 出现 4 次
sg-vless-v6      - 出现 4 次
sg-trojan-v4     - 出现 4 次
sg-trojan-v6     - 出现 4 次
```

## 根本原因

在修复 0.0.0.0 bug 时，为了防止对象修改影响缓存，我在两个位置添加了深拷贝：

### 问题代码 1 (`generator.ts:192`):
```typescript
entries.forEach((v) => proxiesSet.add(JSON.parse(JSON.stringify(v))))
```

### 问题代码 2 (`generator.ts:199`):
```typescript
proxiesSet.add(JSON.parse(JSON.stringify(_proxy)))
```

**为什么会导致重复？**

JavaScript 的 `Set` 使用**严格相等 (===)** 来判断元素是否重复，即通过**对象引用**来判断。

当使用 `JSON.parse(JSON.stringify(obj))` 进行深拷贝时：
- 每次都会创建**新的对象引用**
- Set 认为它们是**不同的对象**
- 即使内容完全相同，也会被重复添加

由于配置生成过程中同一个代理可能被处理 4 次（通过不同的 profile 配置），每次都会创建新引用并添加到 Set，最终导致每个代理重复 4 次。

## 修复方案

### 1. 移除 Set.add 时的深拷贝 (`generator.ts:190, 196`)

**修复前：**
```typescript
// Line 192
entries.forEach((v) => proxiesSet.add(JSON.parse(JSON.stringify(v))))

// Line 199
proxiesSet.add(JSON.parse(JSON.stringify(_proxy)))
```

**修复后：**
```typescript
// Line 190
entries.forEach((v) => proxiesSet.add(v))

// Line 196
proxiesSet.add(_proxy)
```

**原理：**
- 使用原始对象引用添加到 Set
- Set 自动通过引用去重
- 同一个对象引用只会被添加一次

### 2. 简化缓存处理 (`generator.ts:174-181`)

**修复前：**
```typescript
// 在缓存处理时进行深拷贝
SubscriptionCache[subId] = SubscriptionCache[subId]
  .map((entry) => {
    const clone = JSON.parse(JSON.stringify(entry))
    const tag = normalizeProxy(clone)
    return tag ? clone : null
  })
  .filter(Boolean)
```

**修复后：**
```typescript
// 只进行必要的标准化，不做深拷贝
SubscriptionCache[subId] = SubscriptionCache[subId]
  .map((entry) => {
    const tag = normalizeProxy(entry)
    return tag ? entry : null
  })
  .filter(Boolean)
```

## 验证方法

### 构建应用：
```bash
cd /home/user/PrivateDeploy
PATH="/usr/bin:/usr/local/go/bin:/home/user/go/bin:/home/user/.npm-global/bin:$PATH" wails build
```

### 验证配置（重启应用后）：
```python
import json
from collections import Counter

with open('build/bin/data/sing-box/config.json') as f:
    config = json.load(f)

tags = [ob.get('tag', '') for ob in config.get('outbounds', []) if ob.get('tag')]
counter = Counter(tags)
duplicates = {tag: count for tag, count in counter.items() if count > 1}

if duplicates:
    print(f"❌ 发现重复: {duplicates}")
else:
    print(f"✓ 无重复 tag (总共 {len(tags)} 个)")
```

### 预期结果：
```
✓ 无重复 tag (总共 8 个)
```

## 测试步骤

1. **编译应用：**
   ```bash
   cd /home/user/PrivateDeploy
   wails build
   ```

2. **启动应用**（在桌面环境）

3. **验证 sing-box 启动成功：**
   - 不应该看到 "duplicate outbound/endpoint tag" 错误
   - 所有代理应该正常工作

4. **验证配置文件：**
   ```bash
   # 检查 outbound 数量
   python3 -c "import json; c=json.load(open('build/bin/data/sing-box/config.json')); print(f'Outbounds: {len(c[\"outbounds\"])}')"
   # 预期输出: Outbounds: 8-16 (取决于配置)
   ```

## 深层次思考：何时需要深拷贝？

### ❌ 不需要深拷贝的情况：
1. **添加到 Set/Map 时** - 需要保持引用以便去重
2. **只读访问** - 不修改对象，无需拷贝
3. **短生命周期对象** - 很快会被序列化/销毁

### ✅ 需要深拷贝的情况：
1. **从缓存传递给会修改它的函数** - 如果接收方会修改
2. **需要创建独立副本** - 明确需要两份独立数据
3. **防止意外修改共享状态** - 跨组件/模块共享时

### 🎯 本项目的正确策略：
- **订阅缓存 (`SubscriptionCache`)**: 保持原始引用，不修改
- **添加到 Set**: 使用原始引用，让 Set 自动去重
- **配置写入**: 序列化时自动创建副本（`JSON.stringify`）

## 更新日志

- **2025-11-03 15:30**: 发现重复 tag 问题
- **2025-11-03 15:45**: 定位根本原因 - 深拷贝导致 Set 无法去重
- **2025-11-03 16:00**: 实施修复 - 移除不必要的深拷贝
- **2025-11-03 16:15**: 编译成功，等待桌面环境测试

## 相关文件

- `frontend/src/utils/generator.ts` - 配置生成主逻辑
- `FIX-0.0.0.0-BUG.md` - 原始 0.0.0.0 bug 修复文档
- `VERIFICATION-REPORT.md` - 验证报告（需要更新）

## 经验教训

1. **理解 Set 的工作原理** - 使用对象引用判断相等性
2. **深拷贝有副作用** - 破坏引用相等性，影响去重
3. **最小化修改原则** - 只在必要时深拷贝，不要过度防御
4. **测试覆盖完整流程** - 不仅要测试单个功能，还要测试端到端

## 下一步

- ✅ 代码修复完成
- ✅ 编译成功
- ⏳ 等待桌面环境完整测试
- ⏳ 更新验证报告
- ⏳ 提交代码到版本控制
