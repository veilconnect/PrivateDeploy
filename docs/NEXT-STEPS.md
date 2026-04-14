# PrivateDeploy 防火墙自动配置 - 使用指南

## ✅ 编译完成

恭喜！PrivateDeploy 已成功编译，包含完整的 **Vultr 云端防火墙自动配置** 功能。

### 编译信息
- **可执行文件**: `build/bin/PrivateDeploy`
- **文件大小**: 14MB
- **编译时间**: 2025-11-10
- **新增功能**: Vultr 防火墙自动配置

---

## 🚀 下一步操作

### 方案 1：测试新功能（推荐）

#### 1. 删除现有无法连接的节点

现有的节点（如 sg1: 192.0.2.1）没有防火墙配置，需要删除：

```bash
# 通过 PrivateDeploy 图形界面操作：
# 1. 运行应用
DISPLAY=:0 ./build/bin/PrivateDeploy

# 2. 在"云部署"页面找到 sg1 节点
# 3. 点击右侧的"删除"按钮
# 4. 确认删除
```

#### 2. 部署新节点（自动配置防火墙）

使用更新后的应用部署新节点：

**界面操作步骤**：
1. 在"云部署"页面填写：
   - **区域**: 选择 `sgp`（新加坡）或其他区域
   - **配置**: 选择 `vc2-1c-1gb`（1核1GB）
   - **标签**: 例如 `sg-auto-firewall`

2. 点击"部署节点"按钮

3. 等待部署完成（3-5分钟），系统会自动：
   - ✅ 创建 Vultr 实例
   - ✅ 获取或创建防火墙组
   - ✅ 添加所有必要的端口规则
   - ✅ 将防火墙附加到实例
   - ✅ 所有协议立即可用

4. 部署完成后，点击"选用"按钮应用节点

#### 3. 验证防火墙配置

**检查防火墙是否正确应用**：

```bash
# 从 Vultr API 获取实例信息
curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/instances/INSTANCE_ID" | \
  python3 -m json.tool | grep firewall_group_id

# 应该看到一个防火墙组ID（不是空字符串）
```

**测试端口连通性**：

```bash
# 替换为你的节点IP和端口
SERVER_IP="YOUR_SERVER_IP"
SS_PORT="YOUR_SS_PORT"
VLESS_PORT="YOUR_VLESS_PORT"
TROJAN_PORT="YOUR_TROJAN_PORT"

# 扫描TCP端口
nmap -Pn -p $SS_PORT,$VLESS_PORT,$TROJAN_PORT $SERVER_IP

# 结果应该显示端口为 "open" 而不是 "filtered"
```

**查看防火墙规则**：

```bash
# 获取防火墙组ID
FIREWALL_ID=$(curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/instances/INSTANCE_ID" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['instance']['firewall_group_id'])")

# 查看所有规则
curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/rules" | \
  python3 -m json.tool
```

---

### 方案 2：手动修复现有节点

如果你想保留现有的 sg1 节点而不是重新部署，可以手动添加防火墙：

```bash
# 节点信息
INSTANCE_ID="1a949e7a-8fdf-4c21-a8d8-fd6941e32540"
SERVER_IP="192.0.2.1"
SS_PORT=26248
HYSTERIA_PORT=26249
VLESS_PORT=26250
TROJAN_PORT=26251

# 1. 获取或创建防火墙组
FIREWALL_ID="9db9e9cf-f2d5-4c46-89b6-fefdf4307a7d"  # 已存在的防火墙组

# 2. 添加防火墙规则（为所有端口）
for rule in \
  "tcp,$SS_PORT,sg1-Shadowsocks-TCP" \
  "udp,$SS_PORT,sg1-Shadowsocks-UDP" \
  "udp,$HYSTERIA_PORT,sg1-Hysteria2" \
  "tcp,$VLESS_PORT,sg1-VLESS" \
  "tcp,$TROJAN_PORT,sg1-Trojan"
do
  IFS=',' read -r protocol port notes <<< "$rule"
  curl -X POST "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/rules" \
    -H "Authorization: Bearer YOUR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"ip_type\": \"v4\",
      \"protocol\": \"$protocol\",
      \"subnet\": \"0.0.0.0\",
      \"subnet_size\": 0,
      \"port\": \"$port\",
      \"notes\": \"$notes\"
    }"
  echo ""
done

# 3. 将防火墙附加到实例
curl -X PATCH "https://api.vultr.com/v2/instances/$INSTANCE_ID" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"firewall_group_id\": \"$FIREWALL_ID\"}"

# 4. 等待1-2分钟后测试连通性
sleep 120
nmap -Pn -p $SS_PORT,$VLESS_PORT,$TROJAN_PORT $SERVER_IP
```

---

## 📊 功能对比

### 旧版本 vs 新版本

| 特性 | 旧版本 | 新版本（含防火墙自动配置） |
|------|--------|--------------------------|
| 实例创建 | ✅ | ✅ |
| 服务器内部UFW配置 | ✅ | ✅ |
| Vultr云端防火墙 | ❌ **手动配置** | ✅ **自动配置** |
| 防火墙规则管理 | ❌ | ✅ **智能检测，避免重复** |
| 节点即时可用 | ❌ **端口被阻止** | ✅ **立即可用** |
| 多协议支持 | ✅ | ✅ **全部端口自动开放** |

---

## 🔍 故障排查

### 问题1：新部署的节点仍然无法连接

**可能原因**：
- 防火墙配置过程中出错
- API限流或权限问题

**解决方法**：
```bash
# 1. 检查防火墙是否应用
curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/instances/INSTANCE_ID" | \
  grep firewall_group_id

# 2. 如果没有防火墙组ID，手动应用
curl -X PATCH "https://api.vultr.com/v2/instances/INSTANCE_ID" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firewall_group_id": "9db9e9cf-f2d5-4c46-89b6-fefdf4307a7d"}'
```

### 问题2：端口仍然显示 "filtered"

**可能原因**：
- 防火墙规则未生效
- 服务器内部服务未启动

**解决方法**：
```bash
# 1. 等待2-3分钟让防火墙规则生效

# 2. 通过Vultr Web Console登录服务器检查
# 访问: Vultr控制台 -> 实例 -> View Console

# 3. 在控制台中检查UFW状态
sudo ufw status verbose

# 4. 检查Docker容器状态
docker ps -a

# 5. 查看部署日志
cat /var/log/privatedeploy-init.log
```

### 问题3：防火墙组创建失败

**可能原因**：
- API Key权限不足
- Vultr账户限制

**解决方法**：
- 使用现有的防火墙组ID（代码会自动检测）
- 或手动在Vultr控制台创建防火墙组

---

## 📚 相关文档

- **防火墙功能详解**: `FIREWALL-AUTO-CONFIG.md`
- **部署脚本**: `bridge/cloud/deploy/deploy.go`
- **Vultr Provider**: `bridge/cloud/providers/vultr/provider.go`

---

## 🎯 推荐工作流程

### 日常使用

1. **部署新节点**
   - 打开 PrivateDeploy
   - 选择区域和配置
   - 点击"部署" → 自动配置防火墙
   - 等待完成 → 点击"选用"

2. **管理现有节点**
   - 所有节点共享同一个防火墙组
   - 防火墙规则自动累积（不会删除旧规则）
   - 删除节点时，防火墙规则保留（供其他节点使用）

3. **故障处理**
   - 如果节点无法连接，首先检查防火墙是否应用
   - 使用 `nmap` 测试端口状态
   - 查看 Vultr 控制台的防火墙设置

---

## 💡 提示

- ✅ **首次部署**: 会自动创建 "PrivateDeploy Auto-Managed Firewall" 防火墙组
- ✅ **后续部署**: 复用同一个防火墙组，只添加新端口规则
- ✅ **智能检测**: 不会重复添加已存在的端口规则
- ✅ **容错设计**: 防火墙配置失败不影响实例创建

---

## 🎉 开始使用

现在就运行 PrivateDeploy，体验零配置的防火墙自动管理：

```bash
DISPLAY=:0 ./build/bin/PrivateDeploy
```

享受全自动的 VPN 节点部署体验！ 🚀
