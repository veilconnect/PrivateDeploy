# Vultr 防火墙自动配置功能

## 概述

已经为 PrivateDeploy 添加了**自动防火墙配置**功能，解决了 Vultr 节点无法连接的根本问题。

## 问题根源

之前的节点无法连接是因为：
1. ✗ Vultr 实例没有应用云端防火墙组
2. ✗ 即使服务器内部 UFW 配置正确，Vultr 默认会阻止所有未明确允许的端口
3. ✗ 导致 TCP 端口全部被过滤（filtered），只有部分 UDP 流量能通过

## 新功能说明

### 自动化流程

现在当你部署新节点时，系统会自动：

1. **获取或创建防火墙组**
   - 检查是否存在 "PrivateDeploy Auto-Managed Firewall" 防火墙组
   - 如果不存在，自动创建一个新的防火墙组
   - 自动添加 SSH（22端口）访问规则

2. **添加必要的防火墙规则**
   - Shadowsocks（TCP + UDP）
   - Hysteria2（UDP）
   - VLESS-Reality（TCP）
   - Trojan（TCP）
   - 自动检测端口是否已有规则，避免重复添加

3. **应用防火墙到实例**
   - 实例创建并启动后，自动将防火墙组附加到实例
   - 确保所有协议端口都能正常访问

## 代码修改详情

### 新增文件结构

```
bridge/cloud/providers/vultr/provider.go
  ├── 新增类型定义
  │   ├── vultrFirewallGroup  - 防火墙组
  │   └── vultrFirewallRule   - 防火墙规则
  │
  └── 新增方法
      ├── ensureFirewallGroup()      - 获取或创建防火墙组
      ├── addFirewallRule()          - 添加单条防火墙规则
      ├── ensureFirewallRules()      - 确保所有必要规则存在
      └── attachFirewallToInstance() - 将防火墙应用到实例
```

### 修改的核心逻辑

在 `CreateInstance()` 方法中，实例创建完成后自动执行：

```go
// 配置防火墙（在实例激活后）
if firewallID, err := p.ensureFirewallGroup(ctx); err == nil {
    // 为该实例的端口添加防火墙规则
    if err := p.ensureFirewallRules(ctx, firewallID, ssPort, hysteriaPort, vlessPort, trojanPort, opts.Label); err == nil {
        // 将防火墙附加到实例
        _ = p.attachFirewallToInstance(ctx, instanceID, firewallID)
    }
}
```

## 使用方法

### 对于新部署的节点

**完全自动化** - 无需任何额外操作！

1. 在 PrivateDeploy 界面部署新节点
2. 系统自动配置防火墙
3. 节点立即可用

### 对于现有的节点

现有节点（如 sg1: 192.0.2.1）需要重新部署才能应用防火墙：

**方案 A：通过界面重新部署**
1. 打开 PrivateDeploy
2. 在云部署页面找到现有节点
3. 点击"删除"按钮
4. 重新部署一个新节点
5. 新节点会自动配置防火墙

**方案 B：手动为现有节点添加防火墙**
```bash
# 1. 查看防火墙组ID
curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/firewalls"

# 2. 为特定端口添加规则（以26248为例）
curl -X POST "https://api.vultr.com/v2/firewalls/FIREWALL_ID/rules" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "ip_type": "v4",
    "protocol": "tcp",
    "subnet": "0.0.0.0",
    "subnet_size": 0,
    "port": "26248",
    "notes": "sg1 Shadowsocks TCP"
  }'

# 3. 将防火墙附加到实例
curl -X PATCH "https://api.vultr.com/v2/instances/INSTANCE_ID" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firewall_group_id": "FIREWALL_ID"}'
```

## 特性亮点

✅ **完全自动化** - 部署时零配置
✅ **智能检测** - 避免重复添加规则
✅ **多协议支持** - SS、Hysteria2、VLESS、Trojan 全覆盖
✅ **容错设计** - 防火墙配置失败不影响实例创建
✅ **统一管理** - 所有节点共用一个防火墙组，易于管理

## 技术细节

### API 调用流程

```
CreateInstance
    ↓
等待实例激活
    ↓
ensureFirewallGroup (检查/创建防火墙组)
    ↓
ensureFirewallRules (添加端口规则)
    ↓
attachFirewallToInstance (应用到实例)
    ↓
完成 ✓
```

### 错误处理

- 防火墙配置过程中的错误不会导致实例创建失败
- 使用 `_ = ` 忽略防火墙附加错误，确保流程继续
- 所有防火墙相关错误都有详细的错误信息

## 验证方法

部署新节点后，验证防火墙是否正确配置：

```bash
# 1. 检查实例的防火墙状态
curl -s -H "Authorization: Bearer YOUR_API_KEY" \
  "https://api.vultr.com/v2/instances/INSTANCE_ID" | \
  python3 -m json.tool | grep firewall_group_id

# 应该看到非空的防火墙组ID

# 2. 测试端口连通性
nmap -Pn -p SS_PORT,VLESS_PORT,TROJAN_PORT SERVER_IP

# 应该看到端口状态为 "open" 而不是 "filtered"
```

## 未来改进

可能的增强功能：
- [ ] IPv6 防火墙规则支持
- [ ] 自定义防火墙规则
- [ ] 防火墙规则清理（删除旧节点的规则）
- [ ] 防火墙组的 Web UI 管理

## 故障排查

如果新部署的节点仍然无法连接：

1. 检查防火墙组是否已应用：
   ```bash
   curl -s -H "Authorization: Bearer API_KEY" \
     "https://api.vultr.com/v2/instances/INSTANCE_ID" | \
     grep firewall_group_id
   ```

2. 检查防火墙规则是否存在：
   ```bash
   curl -s -H "Authorization: Bearer API_KEY" \
     "https://api.vultr.com/v2/firewalls/FIREWALL_ID/rules"
   ```

3. 检查服务器内部 UFW 状态（通过 Vultr Web Console）：
   ```bash
   sudo ufw status verbose
   ```

## 相关文件

- `bridge/cloud/providers/vultr/provider.go` - Vultr provider 实现
- `bridge/cloud/deploy/deploy.go` - 部署脚本生成
- `FIREWALL-AUTO-CONFIG.md` - 本文档

---

**修改日期**: 2025-11-10
**版本**: 1.0.0
