# PrivateDeploy 部署流程改进文档

## 更新日期
2025-10-16

## 问题描述
原始部署脚本创建的Vultr实例存在Shadowsocks端口无法访问的问题。经诊断发现是服务器内部的UFW防火墙阻止了代理端口。

## 解决方案

### 1. 优化后的User-Data脚本

新的部署脚本(`bridge/vultr.go:582-650`)包含以下改进:

**关键修复 (2025-10-16):**
- ✅ **Docker命令修复** - 添加 `ss-server` 命令作为容器入口点
- ✅ **命令格式优化** - 使用单行格式避免参数解析问题

#### 主要特性
- ✅ **详细日志记录** - 所有输出记录到 `/var/log/privatedeploy-init.log`
- ✅ **分步骤执行** - 5个清晰的步骤,每步都有状态输出
- ✅ **UFW防火墙配置** - 自动配置并启用防火墙规则
- ✅ **Docker容器验证** - 部署后验证容器运行状态
- ✅ **端口监听检查** - 最终验证端口是否正常监听
- ✅ **错误处理** - set -e 确保任何错误都会终止脚本

#### 部署步骤
1. **安装依赖包** - Docker, UFW, iptables
2. **启动Docker服务** - 启用并启动Docker守护进程
3. **配置UFW防火墙** - 开放SSH(22)和Shadowsocks端口
4. **验证防火墙状态** - 确认规则已正确应用
5. **部署Shadowsocks** - 拉取镜像并启动容器

#### 防火墙配置细节
```bash
ufw --force disable || true    # 禁用现有防火墙避免冲突
ufw --force reset               # 重置所有规则
ufw logging on                  # 启用日志
ufw default deny incoming       # 默认拒绝入站
ufw default allow outgoing      # 默认允许出站
ufw allow 22/tcp                # SSH
ufw allow {port}/tcp            # Shadowsocks TCP
ufw allow {port}/udp            # Shadowsocks UDP
echo "y" | ufw enable           # 强制启用
```

### 2. 云端防火墙配置

系统已创建Vultr防火墙组 (ID: `9db9e9cf-f2d5-4c46-89b6-fefdf4307a7d`):
- SSH: 22/tcp
- 所有已部署节点的Shadowsocks端口 (TCP/UDP)

**注意**: 新节点部署后需要通过API将其端口添加到防火墙组。

### 3. 新增工具脚本

#### create-vultr-firewall.sh
通过Vultr API创建和管理防火墙组

#### fix-firewall.sh
通用的防火墙修复脚本,用于修复现有节点

#### fix-current-node.sh
针对特定节点的一键修复脚本

#### web-console-fix-commands.txt
通过Vultr Web控制台手动修复的命令清单

## 使用方法

### 部署新节点
1. 通过VeilDeploy UI创建新实例
2. 系统会自动使用优化后的脚本部署
3. 等待实例状态变为"active"(约3-5分钟)
4. user-data脚本会在后台自动配置防火墙

### 查看部署日志
如果需要诊断问题,可以通过Vultr Web Console登录并查看:
```bash
cat /var/log/privatedeploy-init.log
```

### 验证部署
```bash
# 从本地测试端口连通性
nc -zv <IP> <PORT>

# 或使用nmap
nmap -Pn -p <PORT> <IP>
```

## 已知问题与限制

1. **User-Data执行时间**
   - cloud-init在实例启动后执行
   - 完整部署需要3-10分钟
   - 实例显示"active"时user-data可能还在执行

2. **防火墙配置时序**
   - UFW配置在Docker之前执行
   - 某些情况下UFW可能与已有的iptables规则冲突

3. **日志访问**
   - 需要SSH或Web Console访问才能查看详细日志
   - API无法直接获取user-data执行状态

## 故障排除

### 端口仍然无法访问

1. **检查实例启动时间**
   ```bash
   uptime  # 如果小于5分钟,可能user-data还在执行
   ```

2. **检查user-data日志**
   ```bash
   tail -f /var/log/privatedeploy-init.log
   ```

3. **检查UFW状态**
   ```bash
   ufw status verbose
   ```

4. **检查Docker容器**
   ```bash
   docker ps | grep ss-server
   docker logs ss-server
   ```

5. **手动修复**
   ```bash
   # 重新配置防火墙
   ufw allow <PORT>/tcp
   ufw allow <PORT>/udp
   ufw reload

   # 重启容器
   docker restart ss-server
   ```

## 技术细节

### 关键问题诊断 (2025-10-16 10:30)

**问题**: Docker容器启动失败,错误信息:
```
exec: "-s": executable file not found in $PATH
```

**原因分析:**
1. `teddysun/shadowsocks-libev` 镜像的默认 CMD 是:
   ```
   /usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
   ```
2. 直接传递参数(如 `-s 0.0.0.0`)会被当作可执行文件而不是参数

**解决方案:**
正确的Docker命令格式应该是:
```bash
# 错误 (缺少 ss-server 命令):
docker run -d teddysun/shadowsocks-libev -s 0.0.0.0 -p 31750 ...

# 正确 (明确指定 ss-server):
docker run -d teddysun/shadowsocks-libev ss-server -s 0.0.0.0 -p 31750 ...
```

### 文件修改
- `bridge/vultr.go` (行 582-650): user-data脚本优化
  - 添加 UFW 防火墙配置
  - 修复 Docker 运行命令(添加 `ss-server`)

### API端点
- `POST /v2/instances` - 创建实例
- `PATCH /v2/instances/{id}` - 更新实例配置
- `POST /v2/firewalls/{id}/rules` - 添加防火墙规则

### 日志文件
- `/var/log/privatedeploy-init.log` - 部署脚本执行日志
- `/var/log/cloud-init-output.log` - Cloud-init完整日志

## 未来改进建议

1. **添加部署状态API**
   - 提供端点查询user-data执行状态
   - 实时返回部署进度

2. **自动端口测试**
   - 部署完成后自动测试端口连通性
   - 失败时自动重试或告警

3. **统一防火墙管理**
   - 动态管理Vultr防火墙规则
   - 节点删除时自动清理规则

4. **健康检查**
   - 定期检查节点可用性
   - 自动修复常见问题

## 相关资源

- Vultr API文档: https://www.vultr.com/api/
- UFW文档: https://help.ubuntu.com/community/UFW
- Cloud-init文档: https://cloudinit.readthedocs.io/
