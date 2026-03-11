package deploy

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"

	"golang.org/x/crypto/curve25519"
)

// MultiProtocolParams describes the inputs for the multi-protocol user-data script.
type MultiProtocolParams struct {
	SSPort           int
	SSPassword       string
	HysteriaPort     int
	HysteriaPassword string
	HysteriaServer   string
	HysteriaMasqURL  string
	VLESSPort        int
	VLESSUUID        string
	VLESSPrivateKey  string
	VLESSPublicKey   string
	VLESSShortID     string
	VLESSServer      string
	TrojanPort       int
	TrojanPassword   string
	TrojanServer     string
	SingBoxVersion   string
	SingBoxFallback  string
}

// GenerateUUID returns RFC-4122 UUID v4.
func GenerateUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand is unavailable: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80

	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// GenerateRandomPassword returns a base64 URL-safe password of the requested length.
func GenerateRandomPassword(length int) string {
	if length <= 0 {
		return ""
	}
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand is unavailable: " + err.Error())
	}
	return base64.URLEncoding.EncodeToString(b)[:length]
}

// GenerateRealityKeyPair produces a private/public key pair compatible with sing-box Reality.
func GenerateRealityKeyPair() (privateKey, publicKey string, err error) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return "", "", fmt.Errorf("crypto/rand is unavailable: %w", err)
	}

	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64

	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return "", "", fmt.Errorf("failed to generate Reality public key: %w", err)
	}

	privateKey = base64.RawURLEncoding.EncodeToString(priv)
	publicKey = base64.RawURLEncoding.EncodeToString(pub)

	return privateKey, publicKey, nil
}

// shellEscape safely escapes shell-special characters.
func shellEscape(s string) string {
	if s == "" {
		return "''"
	}
	if strings.ContainsAny(s, " \t\n\\\"'`$") {
		return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
	}
	return s
}

// GenerateMultiProtocolScript renders the multi-protocol deployment bash script.
func GenerateMultiProtocolScript(p MultiProtocolParams) string {
	hysteriaServer := normalizeHostname(p.HysteriaServer, DefaultHysteriaServerName)
	trojanServer := normalizeHostname(p.TrojanServer, DefaultTrojanServerName)
	vlessServer := normalizeHostname(p.VLESSServer, trojanServer)
	if vlessServer == "" {
		vlessServer = DefaultVLESSServerName
	}
	hysteriaMasqueradeURL := normalizeMasqueradeURL(p.HysteriaMasqURL, hysteriaServer)
	singBoxVersion := normalizeVersion(p.SingBoxVersion, DefaultSingBoxVersion)
	singBoxFallback := normalizeVersion(p.SingBoxFallback, singBoxVersion)
	if singBoxFallback == "" {
		singBoxFallback = singBoxVersion
	}

	return fmt.Sprintf(`#!/bin/bash
# PrivateDeploy Multi-Protocol Deployment Script
# Protocols: Shadowsocks, Hysteria2, VLESS-Reality, Trojan
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077

LOGFILE="/var/log/privatedeploy-init.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== PrivateDeploy Multi-Protocol Init Started at $(date) ==="

# Update and install packages
echo "[1/8] Installing Docker, UFW and required packages..."
apt-get update -qq
apt-get install -y docker.io ufw iptables openssl curl ca-certificates net-tools

# Start Docker
echo "[2/8] Starting Docker service..."
systemctl enable docker
systemctl start docker
sleep 3

# Create dedicated service user
useradd --system --no-create-home --shell /usr/sbin/nologin privatedeploy 2>/dev/null || true

# Generate self-signed certificates
echo "[3/8] Generating TLS certificates..."
mkdir -p /etc/privatedeploy/{hysteria,trojan,vless}
chmod 700 /etc/privatedeploy /etc/privatedeploy/hysteria /etc/privatedeploy/trojan /etc/privatedeploy/vless
chown -R privatedeploy:privatedeploy /etc/privatedeploy

generate_cert() {
  local cert_path="$1"
  local key_path="$2"
  local common_name="$3"
  if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -days 30 \
    -subj "/CN=${common_name}" \
    -addext "subjectAltName=DNS:${common_name}" >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$key_path" \
      -out "$cert_path" \
      -days 30 \
      -subj "/CN=${common_name}" >/dev/null 2>&1
  fi
  chmod 600 "$key_path" "$cert_path"
}

generate_cert /etc/privatedeploy/hysteria/cert.pem /etc/privatedeploy/hysteria/key.pem %[12]s
generate_cert /etc/privatedeploy/trojan/cert.pem /etc/privatedeploy/trojan/key.pem %[13]s

# Configure UFW firewall
echo "[4/8] Configuring UFW firewall..."
ufw --force disable || true
ufw --force reset
ufw logging on
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow %[1]d/tcp comment 'Shadowsocks-TCP'
ufw allow %[1]d/udp comment 'Shadowsocks-UDP'
ufw allow %[2]d/udp comment 'Hysteria2'
ufw allow %[3]d/tcp comment 'VLESS-Reality'
ufw allow %[4]d/tcp comment 'Trojan'
echo "y" | ufw enable

echo "[5/8] Verifying firewall configuration..."
ufw status verbose

# Deploy Shadowsocks
echo "[6/8] Deploying Shadowsocks server (port %[1]d)..."
docker rm -f ss-server >/dev/null 2>&1 || true
docker pull --quiet teddysun/shadowsocks-libev || true
docker run -d --name ss-server --restart=always \
  -p %[1]d:%[1]d/tcp -p %[1]d:%[1]d/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p %[1]d -k %[5]s -m aes-256-gcm

sleep 2
echo "Shadowsocks container status:"
docker ps -a --filter "name=ss-server" --format "{{.Names}}: {{.Status}}"

# Prepare Hysteria2 (sing-box inbound) configuration
echo "[7/8] Preparing Hysteria2 server config (port %[2]d)..."
HYSTERIA_PASSWORD=%[6]s
HYSTERIA_SERVER_NAME=%[12]s
HYSTERIA_MASQ_URL=%[14]s
cat > /etc/privatedeploy/hysteria/config.json <<HYSTEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    "listen_port": %[2]d,
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [{
      "password": "${HYSTERIA_PASSWORD}"
    }],
    "masquerade": "${HYSTERIA_MASQ_URL}",
    "tls": {
      "enabled": true,
      "server_name": "${HYSTERIA_SERVER_NAME}",
      "certificate_path": "/etc/privatedeploy/hysteria/cert.pem",
      "key_path": "/etc/privatedeploy/hysteria/key.pem"
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
HYSTEOF
chmod 600 /etc/privatedeploy/hysteria/config.json

# Deploy sing-box based services
echo "[8/8] Deploying sing-box services (Hysteria2, VLESS-Reality, Trojan)..."

SINGBOX_VERSION="%[15]s"
SINGBOX_FALLBACK_VERSION="%[16]s"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
FALLBACK_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_FALLBACK_VERSION}/sing-box-${SINGBOX_FALLBACK_VERSION}-linux-amd64.tar.gz"

mkdir -p /tmp/privatedeploy
if ! curl -fsSLo /tmp/privatedeploy/singbox.tar.gz "$SINGBOX_URL"; then
  if [ -n "$SINGBOX_FALLBACK_VERSION" ] && [ "$SINGBOX_FALLBACK_VERSION" != "$SINGBOX_VERSION" ]; then
    echo "[WARN] Failed to download sing-box ${SINGBOX_VERSION}, attempting fallback ${SINGBOX_FALLBACK_VERSION}..." >&2
    if ! curl -fsSLo /tmp/privatedeploy/singbox.tar.gz "$FALLBACK_URL"; then
      echo "[ERROR] Could not download sing-box binaries. Skipping VLESS/Trojan deployment." >&2
      SKIP_SINGBOX=1
    else
      SINGBOX_VERSION="$SINGBOX_FALLBACK_VERSION"
    fi
  else
    echo "[ERROR] Could not download sing-box ${SINGBOX_VERSION} and no valid fallback is configured. Skipping VLESS/Trojan deployment." >&2
    SKIP_SINGBOX=1
  fi
fi

if [ "${SKIP_SINGBOX:-0}" -ne 1 ]; then
  tar -xzf /tmp/privatedeploy/singbox.tar.gz -C /tmp/privatedeploy
  find /tmp/privatedeploy -name "sing-box" -type f -executable -exec mv {} /usr/local/bin/sing-box \;
  chmod +x /usr/local/bin/sing-box

  docker rm -f hysteria-server >/dev/null 2>&1 || true
  cat > /etc/systemd/system/hysteria-server.service <<'HYSTERIASERVICE'
[Unit]
Description=Hysteria2 Server (sing-box)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/privatedeploy/hysteria/config.json
Restart=always
RestartSec=5
User=privatedeploy
Group=privatedeploy
ProtectSystem=strict
ReadWritePaths=/etc/privatedeploy
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HYSTERIASERVICE

  systemctl daemon-reload
  systemctl enable hysteria-server
  systemctl start hysteria-server

  sleep 3
  echo "Hysteria2 service status:"
  systemctl status hysteria-server --no-pager --lines=10 || journalctl -u hysteria-server -n 20 --no-pager

  cat > /etc/privatedeploy/vless/config.json <<VLESSEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": %[3]d,
    "users": [{
      "uuid": "%[8]s",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "%[17]s",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "%[17]s",
          "server_port": 443
        },
        "private_key": "%[9]s",
        "short_id": ["%[10]s"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
VLESSEOF
  chmod 600 /etc/privatedeploy/vless/config.json

  cat > /etc/privatedeploy/vless/reality.txt <<REALITYINFO
PublicKey: %[11]s
ShortID: %[10]s
REALITYINFO
  chmod 600 /etc/privatedeploy/vless/reality.txt

  cat > /etc/systemd/system/vless-server.service <<'SERVICEEOF'
[Unit]
Description=VLESS-Reality Server (sing-box)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/privatedeploy/vless/config.json
Restart=always
RestartSec=5
User=privatedeploy
Group=privatedeploy
ProtectSystem=strict
ReadWritePaths=/etc/privatedeploy
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

  systemctl daemon-reload
  systemctl enable vless-server
  systemctl start vless-server

  sleep 3
  echo "VLESS-Reality service status:"
  systemctl status vless-server --no-pager --lines=10 || journalctl -u vless-server -n 20 --no-pager

  cat > /etc/privatedeploy/trojan/config.json <<'TROJANEOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "trojan",
    "tag": "trojan-in",
    "listen": "::",
    "listen_port": %[4]d,
    "users": [{
      "password": "%[7]s"
    }],
    "tls": {
      "enabled": true,
      "server_name": "%[13]s",
      "key_path": "/etc/privatedeploy/trojan/key.pem",
      "certificate_path": "/etc/privatedeploy/trojan/cert.pem"
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
TROJANEOF
  chmod 600 /etc/privatedeploy/trojan/config.json

  cat > /etc/systemd/system/trojan-server.service <<'TROJANSERVICE'
[Unit]
Description=Trojan Server (sing-box)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/privatedeploy/trojan/config.json
Restart=always
RestartSec=5
User=privatedeploy
Group=privatedeploy
ProtectSystem=strict
ReadWritePaths=/etc/privatedeploy
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
TROJANSERVICE

  systemctl daemon-reload
  systemctl enable trojan-server
  systemctl start trojan-server

  sleep 3
  echo "Trojan service status:"
  systemctl status trojan-server --no-pager --lines=10 || journalctl -u trojan-server -n 20 --no-pager
else
  echo "[WARN] sing-box installation skipped; Hysteria2, VLESS and Trojan services were not provisioned." >&2
fi

# Configure certificate rotation timer (daily check, rotate every 14 days)
cat > /usr/local/bin/privatedeploy-rotate-certs.sh <<'ROTATEEOF'
#!/bin/bash
set -euo pipefail
umask 077

generate_cert() {
  local cert_path="$1"
  local key_path="$2"
  local common_name="$3"
  if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -days 30 \
    -subj "/CN=${common_name}" \
    -addext "subjectAltName=DNS:${common_name}" >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$key_path" \
      -out "$cert_path" \
      -days 30 \
      -subj "/CN=${common_name}" >/dev/null 2>&1
  fi
  chmod 600 "$key_path" "$cert_path"
}

renew_if_due() {
  local cert_path="$1"
  local key_path="$2"
  local common_name="$3"
  if [ ! -f "$cert_path" ] || ! openssl x509 -checkend $((14*24*3600)) -noout -in "$cert_path" >/dev/null 2>&1; then
    generate_cert "$cert_path" "$key_path" "$common_name"
    return 0
  fi
  return 1
}

changed=0
if renew_if_due /etc/privatedeploy/hysteria/cert.pem /etc/privatedeploy/hysteria/key.pem %[12]s; then
  changed=1
fi
if renew_if_due /etc/privatedeploy/trojan/cert.pem /etc/privatedeploy/trojan/key.pem %[13]s; then
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  chown -R privatedeploy:privatedeploy /etc/privatedeploy
  systemctl restart hysteria-server >/dev/null 2>&1 || true
  systemctl restart trojan-server >/dev/null 2>&1 || true
fi
ROTATEEOF
chmod 700 /usr/local/bin/privatedeploy-rotate-certs.sh

cat > /etc/systemd/system/privatedeploy-cert-rotate.service <<'CERTSERVICE'
[Unit]
Description=PrivateDeploy certificate rotation
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/privatedeploy-rotate-certs.sh
CERTSERVICE

cat > /etc/systemd/system/privatedeploy-cert-rotate.timer <<'CERTTIMER'
[Unit]
Description=Run PrivateDeploy certificate rotation daily

[Timer]
OnCalendar=*-*-* 04:15:00
Persistent=true

[Install]
WantedBy=timers.target
CERTTIMER

systemctl daemon-reload
systemctl enable --now privatedeploy-cert-rotate.timer >/dev/null 2>&1 || true

# Cleanup temp files
rm -rf /tmp/privatedeploy

# Verification and summary
sleep 5
echo ""
echo "=== Deployment Summary ==="
echo "Firewall status:"
ufw status numbered || true
echo ""
echo "Docker containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Systemd services:"
echo "  Hysteria2: $(systemctl is-active hysteria-server 2>/dev/null || echo 'inactive')"
echo "  VLESS-Reality: $(systemctl is-active vless-server 2>/dev/null || echo 'inactive')"
echo "  Trojan: $(systemctl is-active trojan-server 2>/dev/null || echo 'inactive')"
echo ""
echo "Listening ports:"
ss -tlnup | grep -E ':%[1]d |:%[2]d |:%[3]d |:%[4]d ' || echo 'Warning: Some ports not yet listening'
echo ""
echo "Protocol Configuration:"
echo "  [1] Shadowsocks:    Port %[1]d (TCP/UDP) - Password: %[5]s"
echo "  [2] Hysteria2:      Port %[2]d (UDP) - Password: %[6]s"
echo "  [3] VLESS-Reality:  Port %[3]d (TCP) - UUID: %[8]s"
echo "                     Public Key: %[11]s"
echo "                     Short ID: %[10]s"
echo "  [4] Trojan:         Port %[4]d (TCP) - Password: %[7]s"
echo ""
echo "=== PrivateDeploy Multi-Protocol Init Completed at $(date) ==="
`,
		p.SSPort,
		p.HysteriaPort,
		p.VLESSPort,
		p.TrojanPort,
		shellEscape(p.SSPassword),
		shellEscape(p.HysteriaPassword),
		shellEscape(p.TrojanPassword),
		p.VLESSUUID,
		p.VLESSPrivateKey,
		p.VLESSShortID,
		p.VLESSPublicKey,
		hysteriaServer,
		trojanServer,
		hysteriaMasqueradeURL,
		singBoxVersion,
		singBoxFallback,
		vlessServer,
	)
}

// GenerateLightweightScript returns the Shadowsocks-only bootstrap script.
func GenerateLightweightScript(ssPort int, ssPassword string) string {
	return fmt.Sprintf(`#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077

LOGFILE="/var/log/privatedeploy-init.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== PrivateDeploy Lightweight Init Started at $(date) ==="

apt-get update -qq
apt-get install -y docker.io ufw

systemctl enable docker
systemctl start docker

ufw --force disable || true
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow %[1]d/tcp comment 'Shadowsocks-TCP'
ufw allow %[1]d/udp comment 'Shadowsocks-UDP'
echo "y" | ufw enable

docker rm -f ss-server >/dev/null 2>&1 || true
docker pull --quiet teddysun/shadowsocks-libev || true
docker run -d --name ss-server --restart=always \
  -p %[1]d:%[1]d/tcp -p %[1]d:%[1]d/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p %[1]d -k %[2]s -m aes-256-gcm

sleep 3
echo "Shadowsocks container status:"
docker ps -a --filter "name=ss-server" --format "{{.Names}}: {{.Status}}"

echo ""
echo "=== PrivateDeploy Lightweight Init Completed at $(date) ==="
`, ssPort, shellEscape(ssPassword))
}

