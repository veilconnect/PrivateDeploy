# PrivateDeploy Multi-Protocol Deployment Design

**English** | [中文](MULTI-PROTOCOL-DESIGN.zh-CN.md)

## Update Date
2025-10-16

## Implementation Status
✅ **Completed** - All 4 protocols have been integrated into the deployment script

## Goal
Deploy 4 VPN protocols simultaneously on a single Vultr VPS to provide the strongest anti-censorship capability and flexibility.

## Protocol Configuration

### 1. Shadowsocks (Implemented)
- **Port**: Base port (e.g.: 23281)
- **Encryption**: aes-256-gcm
- **Docker Image**: teddysun/shadowsocks-libev
- **Use Case**: Speed-first, fallback option

### 2. Hysteria2 (New)
- **Port**: Base port + 1 (e.g.: 23282)
- **Protocol**: QUIC (UDP)
- **Docker Image**: tobyxdd/hysteria:latest
- **Masquerade**: Mimics HTTP/3 traffic
- **Use Case**: Primary protocol, strongest anti-censorship

### 3. VLESS-Reality (New)
- **Port**: Base port + 2 (e.g.: 23283)
- **Protocol**: VLESS + Reality
- **Implementation**: sing-box server mode
- **Masquerade**: Borrows a real website's certificate
- **Use Case**: Ultimate stealth, sensitive periods

### 4. Trojan-GFW (New)
- **Port**: Base port + 3 (e.g.: 23284)
- **Protocol**: Trojan
- **Docker Image**: trojangfw/trojan
- **Masquerade**: HTTPS traffic
- **Use Case**: Balanced option

## Port Allocation Strategy

```
Base port: random port returned by randomPort()
├─ Shadowsocks:    basePort + 0 (TCP/UDP)
├─ Hysteria2:      basePort + 1 (UDP)
├─ VLESS-Reality:  basePort + 2 (TCP)
└─ Trojan:         basePort + 3 (TCP)

Example (basePort = 23281):
├─ SS:       23281 (TCP/UDP)
├─ Hysteria: 23282 (UDP)
├─ VLESS:    23283 (TCP)
└─ Trojan:   23284 (TCP)
```

## Resource Consumption Estimate

### Under a 1GB VPS configuration:
- Shadowsocks: ~15MB
- Hysteria2: ~25MB
- VLESS (sing-box): ~30MB
- Trojan: ~20MB
**Total**: ~90MB (9% of 1GB)

## Docker Container Naming

```bash
ss-server         # Shadowsocks
hysteria-server   # Hysteria2
vless-server      # VLESS-Reality (sing-box)
trojan-server     # Trojan-GFW
```

## Configuration File Generation

### Hysteria2 Configuration
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

### VLESS-Reality Configuration
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

### Trojan Configuration
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

## Deployment Process

### 1. System Preparation
```bash
apt-get update
apt-get install -y docker.io ufw iptables openssl
```

### 2. Generate Self-Signed Certificate
```bash
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /tmp/key.pem -out /tmp/cert.pem \
  -days 365 -subj "/CN=example.com"
```

### 3. Deploy Containers
Start the 4 containers in order, each container configured independently

### 4. Configure Firewall
```bash
ufw allow 22/tcp
ufw allow ${basePort}/tcp
ufw allow ${basePort}/udp
ufw allow ${basePort+1}/udp
ufw allow ${basePort+2}/tcp
ufw allow ${basePort+3}/tcp
ufw --force enable
```

## Client Configuration Generation

A corresponding configuration must be generated for each protocol:
- Shadowsocks: ss://...
- Hysteria2: hysteria2://...
- VLESS: vless://...
- Trojan: trojan://...

## Priority Recommendation

Usage priority in the Sing-box client:
1. Hysteria2 (primary)
2. VLESS-Reality (backup)
3. Trojan (backup)
4. Shadowsocks (last resort)

## Notes

1. **Certificate Issue**: Trojan and Hysteria require TLS certificates; use self-signed certificates
2. **Reality Keys**: VLESS-Reality requires generating a key pair
3. **UUID Generation**: VLESS requires a UUID
4. **Port Occupancy**: Ensure the 4 ports do not conflict
5. **Memory Limit**: Monitor total memory usage; a 1GB VPS is slightly tight

## Simplified Solution (Recommended)

If resources are tight, you can first deploy 3 protocols:
- Shadowsocks (fast, simple)
- Hysteria2 (anti-censorship)
- VLESS-Reality (ultimate stealth)

Omit Trojan, because its function overlaps with VLESS.

## Implementation Details (2025-10-16)

### Code Changes

**Modified file**: `bridge/vultr.go`

1. **Added UUID generation function** (lines 292-304)
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

2. **Extended data structures** (lines 74-115)
   - `vultrNodeRecord`: added multi-protocol fields
   - `VultrNode`: added multi-protocol fields
   - Maintained backward compatibility (Port/Password fields mapped to SS)

3. **User-Data script enhancement** (lines 591-839)
   - 8-step deployment process
   - Automatic TLS certificate generation
   - Reality key generation
   - Deployment of 4 containers/services
   - Detailed logging

4. **Data persistence** (lines 894-911)
   - Save ports and passwords for all protocols
   - Backward compatible with older-version data

### Deployment Script Features

1. **Automatic certificate generation**
   - Hysteria2: self-signed certificate (CN=www.bing.com)
   - Trojan: self-signed certificate (CN=www.microsoft.com)
   - VLESS: Reality key + Short ID

2. **Containerized deployment**
   - Shadowsocks: Docker (teddysun/shadowsocks-libev)
   - Hysteria2: Docker (tobyxdd/hysteria:latest)
   - VLESS-Reality: Systemd service (sing-box binary)
   - Trojan: Docker (trojangfw/trojan)

3. **Firewall configuration**
   - SSH: 22/tcp
   - Shadowsocks: basePort/tcp+udp
   - Hysteria2: basePort+1/udp
   - VLESS: basePort+2/tcp
   - Trojan: basePort+3/tcp

4. **Health check**
   - Docker container status verification
   - Systemd service status check
   - Port listening verification

### Testing Recommendations

After deployment, verify in the following ways:

1. **SSH into the server**:
```bash
ssh root@<IP>
cat /var/log/veildeploy-init.log
```

2. **Check container status**:
```bash
docker ps | grep -E 'ss-server|hysteria|trojan'
systemctl status vless-server
```

3. **Check port listening**:
```bash
netstat -tlnup | grep -E '<ports>'
```

4. **Firewall verification**:
```bash
ufw status verbose
```

### Known Issues

1. **Hysteria2 configuration path issue**
   - In-container path: /etc/hysteria/
   - Host path: /etc/veildeploy/hysteria/
   - Needs to be mapped via volume

2. **Trojan Docker image**
   - The official image may be outdated
   - Consider using trojan-go or another fork

3. **Reality key storage**
   - Keys are generated in the script, not saved to vultr-nodes.json
   - The client cannot retrieve them automatically; manual configuration is required

### Future Improvements

1. **Client configuration generator**
   - Generate standard URIs for each protocol
   - Sing-box configuration file generation

2. **Reality key persistence**
   - Save the Reality private key to the database
   - Provide an API query interface

3. **Protocol priority management**
   - Set priority in the client configuration
   - Hysteria2 > VLESS > Trojan > Shadowsocks

4. **Health monitoring**
   - Periodically check the availability of each protocol
   - Automatically switch over a failed protocol
