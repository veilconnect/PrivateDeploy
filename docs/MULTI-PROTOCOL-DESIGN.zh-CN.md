# PrivateDeploy 多协议部署方案设计

[English](MULTI-PROTOCOL-DESIGN.md) | **中文**

## 更新日期
2025-10-16

## 实现状态
✅ **已完成** - 所有4种协议已集成到部署脚本中

## 目标
在单个Vultr VPS上同时部署4种VPN协议,提供最强的抗封锁能力和灵活性。

## 协议配置

### 1. Shadowsocks (已实现)
- **端口**: 基础端口 (如: 23281)
- **加密**: aes-256-gcm
- **Docker镜像**: teddysun/shadowsocks-libev
- **用途**: 速度优先,备用方案

### 2. Hysteria2 (新增)
- **端口**: 基础端口 + 1 (如: 23282)
- **协议**: QUIC (UDP)
- **Docker镜像**: tobyxdd/hysteria:latest
- **伪装**: 模拟HTTP/3流量
- **用途**: 主力协议,抗封锁最强

### 3. VLESS-Reality (新增)
- **端口**: 基础端口 + 2 (如: 23283)
- **协议**: VLESS + Reality
- **实现**: sing-box server mode
- **伪装**: 借用真实网站证书
- **用途**: 极致隐蔽性,敏感时期

### 4. Trojan-GFW (新增)
- **端口**: 基础端口 + 3 (如: 23284)
- **协议**: Trojan
- **Docker镜像**: trojangfw/trojan
- **伪装**: HTTPS流量
- **用途**: 平衡方案

## 端口分配策略

```
基础端口: randomPort() 返回的随机端口
├─ Shadowsocks:    basePort + 0 (TCP/UDP)
├─ Hysteria2:      basePort + 1 (UDP)
├─ VLESS-Reality:  basePort + 2 (TCP)
└─ Trojan:         basePort + 3 (TCP)

示例 (basePort = 23281):
├─ SS:       23281 (TCP/UDP)
├─ Hysteria: 23282 (UDP)
├─ VLESS:    23283 (TCP)
└─ Trojan:   23284 (TCP)
```

## 资源消耗估算

### 1GB VPS配置下:
- Shadowsocks: ~15MB
- Hysteria2: ~25MB
- VLESS (sing-box): ~30MB
- Trojan: ~20MB
**总计**: ~90MB (9% of 1GB)

## Docker容器命名

```bash
ss-server         # Shadowsocks
hysteria-server   # Hysteria2
vless-server      # VLESS-Reality (sing-box)
trojan-server     # Trojan-GFW
```

## 配置文件生成

### Hysteria2 配置
```yaml
listen: :${PORT}
tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
auth:
  type: password
  password: ${PASSWORD}
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
```

### VLESS-Reality 配置
```json
{
  "log": {
    "level": "info"
  },
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": ${PORT},
    "users": [{
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "www.microsoft.com",
          "server_port": 443
        },
        "private_key": "${PRIVATE_KEY}",
        "short_id": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct"
  }]
}
```

### Trojan 配置
```json
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["${PASSWORD}"],
  "ssl": {
    "cert": "/etc/trojan/cert.pem",
    "key": "/etc/trojan/key.pem",
    "sni": "${DOMAIN}"
  }
}
```

## 部署流程

### 1. 系统准备
```bash
apt-get update
apt-get install -y docker.io ufw iptables openssl
```

### 2. 生成自签名证书
```bash
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /tmp/key.pem -out /tmp/cert.pem \
  -days 365 -subj "/CN=example.com"
```

### 3. 部署容器
按顺序启动4个容器,每个容器独立配置

### 4. 配置防火墙
```bash
ufw allow 22/tcp
ufw allow ${basePort}/tcp
ufw allow ${basePort}/udp
ufw allow ${basePort+1}/udp
ufw allow ${basePort+2}/tcp
ufw allow ${basePort+3}/tcp
ufw --force enable
```

## 客户端配置生成

需要为每个协议生成对应的配置:
- Shadowsocks: ss://...
- Hysteria2: hysteria2://...
- VLESS: vless://...
- Trojan: trojan://...

## 优先级建议

Sing-box客户端中的使用优先级:
1. Hysteria2 (主力)
2. VLESS-Reality (备用)
3. Trojan (备用)
4. Shadowsocks (最后备用)

## 注意事项

1. **证书问题**: Trojan和Hysteria需要TLS证书,使用自签名证书
2. **Reality密钥**: VLESS-Reality需要生成密钥对
3. **UUID生成**: VLESS需要UUID
4. **端口占用**: 确保4个端口不冲突
5. **内存限制**: 监控总内存使用,1GB VPS略紧张

## 简化方案(推荐)

如果资源紧张,可以先部署3个协议:
- Shadowsocks (快速,简单)
- Hysteria2 (抗封锁)
- VLESS-Reality (极致隐蔽)

省略Trojan,因为功能与VLESS重叠。

## 实现细节 (2025-10-16)

### 代码修改

**修改文件**: `bridge/vultr.go`

1. **新增 UUID 生成函数** (行 292-304)
```go
func generateUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		mathrand.Read(b)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
```

2. **扩展数据结构** (行 74-115)
   - `vultrNodeRecord`: 添加多协议字段
   - `VultrNode`: 添加多协议字段
   - 保持向后兼容 (Port/Password 字段映射到 SS)

3. **User-Data 脚本增强** (行 591-839)
   - 8步部署流程
   - 自动生成 TLS 证书
   - Reality 密钥生成
   - 4个容器/服务部署
   - 详细日志记录

4. **数据持久化** (行 894-911)
   - 保存所有协议的端口和密码
   - 向后兼容旧版本数据

### 部署脚本特点

1. **证书自动生成**
   - Hysteria2: 自签名证书 (CN=www.bing.com)
   - Trojan: 自签名证书 (CN=www.microsoft.com)
   - VLESS: Reality 密钥 + Short ID

2. **容器化部署**
   - Shadowsocks: Docker (teddysun/shadowsocks-libev)
   - Hysteria2: Docker (tobyxdd/hysteria:latest)
   - VLESS-Reality: Systemd 服务 (sing-box binary)
   - Trojan: Docker (trojangfw/trojan)

3. **防火墙配置**
   - SSH: 22/tcp
   - Shadowsocks: basePort/tcp+udp
   - Hysteria2: basePort+1/udp
   - VLESS: basePort+2/tcp
   - Trojan: basePort+3/tcp

4. **健康检查**
   - Docker 容器状态验证
   - Systemd 服务状态检查
   - 端口监听验证

### 测试建议

部署后通过以下方式验证:

1. **SSH 登录服务器**:
```bash
ssh root@<IP>
cat /var/log/veildeploy-init.log
```

2. **检查容器状态**:
```bash
docker ps | grep -E 'ss-server|hysteria|trojan'
systemctl status vless-server
```

3. **检查端口监听**:
```bash
netstat -tlnup | grep -E '<ports>'
```

4. **防火墙验证**:
```bash
ufw status verbose
```

### 已知问题

1. **Hysteria2 配置路径问题**
   - 容器内路径: /etc/hysteria/
   - 主机路径: /etc/veildeploy/hysteria/
   - 需要通过 volume 映射

2. **Trojan Docker镜像**
   - 官方镜像可能过时
   - 考虑使用 trojan-go 或其他分支

3. **Reality 密钥存储**
   - 密钥在脚本中生成,未保存到 vultr-nodes.json
   - 客户端无法自动获取,需手动配置

### 后续改进

1. **客户端配置生成器**
   - 为每个协议生成标准URI
   - Sing-box 配置文件生成

2. **Reality 密钥持久化**
   - 将 Reality 私钥保存到数据库
   - 提供 API 查询接口

3. **协议优先级管理**
   - 在客户端配置中设置优先级
   - Hysteria2 > VLESS > Trojan > Shadowsocks

4. **健康监控**
   - 定期检查各协议可用性
   - 自动切换故障协议
