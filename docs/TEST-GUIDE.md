# PrivateDeploy 修复测试指南

**修复版本:** 2025-11-03
**编译时间:** 12.701秒
**编译路径:** `/home/user/PrivateDeploy/build/bin/PrivateDeploy`

## 已修复的问题

### 1. ✅ 0.0.0.0 服务器地址 Bug
- **问题:** 配置生成时 server 字段变成 0.0.0.0
- **根因:** 对象引用共享导致意外修改
- **修复:** 多层防护 + 配置验证
- **文档:** `FIX-0.0.0.0-BUG.md`

### 2. ✅ 重复 Outbound Tag Bug
- **问题:** duplicate outbound/endpoint tag: sg-ss-v4
- **根因:** 深拷贝破坏 Set 去重机制
- **修复:** 移除不必要的深拷贝
- **文档:** `FIX-DUPLICATE-TAGS.md`

## 测试步骤

### 前置准备

1. **停止旧版本应用：**
   ```bash
   pkill -f PrivateDeploy
   pkill -f sing-box
   ```

2. **备份当前配置（可选）：**
   ```bash
   cp -r build/bin/data build/bin/data.backup-$(date +%Y%m%d_%H%M%S)
   ```

### 测试 1: 启动应用

```bash
cd /home/user/PrivateDeploy
./build/bin/PrivateDeploy
```

**预期结果：**
- ✅ 应用正常启动
- ✅ 无 GTK 错误
- ✅ 界面正常显示

### 测试 2: 验证 sing-box 启动

观察控制台日志或应用内日志：

**预期看到：**
```
[App] Auto-starting kernel...
[App] Kernel started successfully
```

**不应该看到：**
```
❌ FATAL[0000] decode config: duplicate outbound/endpoint tag: sg-ss-v4
❌ Invalid server address detected: "0.0.0.0"
```

### 测试 3: 检查配置文件

```bash
# 测试 3.1: 检查 outbound 数量
python3 << 'EOF'
import json
config_path = 'build/bin/data/sing-box/config.json'
with open(config_path) as f:
    config = json.load(f)
outbounds = config.get('outbounds', [])
print(f"✓ Outbound 总数: {len(outbounds)}")
EOF
```

**预期输出：** `✓ Outbound 总数: 8-16` (取决于节点数量)

```bash
# 测试 3.2: 检查重复 tag
python3 << 'EOF'
import json
from collections import Counter

config_path = 'build/bin/data/sing-box/config.json'
with open(config_path) as f:
    config = json.load(f)

tags = [ob.get('tag', '') for ob in config.get('outbounds', []) if ob.get('tag')]
counter = Counter(tags)
duplicates = {tag: count for tag, count in counter.items() if count > 1}

if duplicates:
    print(f"❌ 发现重复 tag:")
    for tag, count in duplicates.items():
        print(f"  • {tag}: {count} 次")
    exit(1)
else:
    print(f"✓ 无重复 tag (总共 {len(tags)} 个)")
EOF
```

**预期输出：** `✓ 无重复 tag (总共 8 个)`

```bash
# 测试 3.3: 检查 0.0.0.0
python3 << 'EOF'
import json

config_path = 'build/bin/data/sing-box/config.json'
with open(config_path) as f:
    config = json.load(f)

invalid_count = 0
for ob in config.get('outbounds', []):
    server = ob.get('server', '')
    if server in ['0.0.0.0', '::', '']:
        print(f"❌ {ob.get('tag')}: server = \"{server}\"")
        invalid_count += 1

if invalid_count == 0:
    print("✓ 所有 outbound 的 server 地址都有效")
else:
    print(f"❌ 发现 {invalid_count} 个无效地址")
    exit(1)
EOF
```

**预期输出：** `✓ 所有 outbound 的 server 地址都有效`

### 测试 4: 验证代理连通性

```bash
# 测试所有协议的延迟
for proto in ss hysteria2 vless trojan; do
    echo "测试 sg-${proto}-v4..."
    curl -s -H "Authorization: Bearer b23cda9d2746e7656027c9d2252c1c30fd2b8d35b89ce0f2626283973228e3ce" \
      "http://127.0.0.1:20123/proxies/sg-${proto}-v4/delay?url=https://www.gstatic.com/generate_204&timeout=10000"
    echo ""
done
```

**预期结果：**
```json
{"delay": 150}  // 或其他正常延迟值，不是 503/504
```

### 测试 5: 部署新节点（可选）

1. 在 CloudView 页面部署一个新节点
2. 等待节点状态变为 "active"
3. 点击"使用节点"

**预期结果：**
- ✅ 订阅文件正确生成（IP 地址正确）
- ✅ sing-box 配置正确更新（IP 地址正确）
- ✅ sing-box 重启成功
- ✅ 新节点可以正常连接

## 验证清单

### 核心功能
- [ ] 应用启动成功
- [ ] sing-box 启动成功（无 duplicate tag 错误）
- [ ] 配置文件无重复 tag
- [ ] 配置文件无 0.0.0.0 地址
- [ ] 所有现有代理可以连接

### 新节点部署
- [ ] 新节点部署成功
- [ ] 订阅文件生成正确
- [ ] 配置文件更新正确
- [ ] sing-box 自动重启
- [ ] 新节点可以连接

### 边界情况
- [ ] 多次重启应用，配置保持正确
- [ ] 切换不同的 profile，配置正确
- [ ] 删除节点后，配置正确更新

## 如果测试失败

### 问题 1: 仍然有 duplicate tag

**可能原因：**
- 旧的配置文件没有被清理
- 缓存没有被清除

**解决方案：**
```bash
# 清理配置和缓存
rm build/bin/data/sing-box/config.json
rm -rf build/bin/data/sing-box/cache.db*
# 重启应用
```

### 问题 2: 仍然有 0.0.0.0

**可能原因：**
- 订阅文件本身有问题
- IP 地址还未分配

**解决方案：**
```bash
# 检查订阅文件
cat build/bin/data/subscribes/cloud-*.json | grep "server"

# 如果订阅文件正确但配置错误，报告 bug
# 如果订阅文件也是 0.0.0.0，等待 IP 分配或重新部署节点
```

### 问题 3: 编译版本不对

**验证是否使用了新版本：**
```bash
ls -lh build/bin/PrivateDeploy
# 检查修改时间是否是 2025-11-03
```

## 报告结果

测试完成后，请报告：

1. ✅ / ❌ 验证清单结果
2. 任何异常日志或错误信息
3. 配置文件截图（可选）

## 相关文档

- `FIX-0.0.0.0-BUG.md` - 0.0.0.0 bug 详细说明
- `FIX-DUPLICATE-TAGS.md` - 重复 tag bug 详细说明
- `VERIFICATION-REPORT.md` - 静态验证报告

## 修改的代码文件

```
M  frontend/src/stores/cloud.ts        (+14 行)
M  frontend/src/utils/generator.ts     (+25 -4 行)
```

---

**构建信息：**
- 构建时间: 2025-11-03
- 构建耗时: 12.701 秒
- 构建路径: /home/user/PrivateDeploy/build/bin/PrivateDeploy
- 构建环境: linux/amd64

**准备就绪，开始测试！** 🚀
