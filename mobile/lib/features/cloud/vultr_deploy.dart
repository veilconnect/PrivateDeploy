import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vultr_client.dart';

const int lightweightPlanRamThresholdMb = 600;
const String defaultSingBoxVersion = '1.11.0';
const String defaultHysteriaServerName = 'www.bing.com';
const String defaultHysteriaMasqueradeUrl = 'https://www.bing.com';
const String defaultVlessServerName = 'www.microsoft.com';
const String defaultTrojanServerName = 'www.microsoft.com';

class VultrDeploymentBundle {
  final String userData;
  final Map<String, dynamic> nodeRecord;
  final bool lightweight;

  const VultrDeploymentBundle({
    required this.userData,
    required this.nodeRecord,
    required this.lightweight,
  });
}

class VultrDeploymentBuilder {
  const VultrDeploymentBuilder._();

  static Future<VultrDeploymentBundle> build({
    required int planRam,
    required String portProfile,
  }) async {
    final ports = PortProfileAllocator.allocatePorts(profile: portProfile);
    final ssPort = ports[0];
    final ssPassword = PortProfileAllocator.generatePassword(22);

    if (_isLightweight(planRam)) {
      return VultrDeploymentBundle(
        userData: PortProfileAllocator.lightweightScript(
          ssPort: ssPort,
          ssPassword: ssPassword,
        ),
        nodeRecord: {
          'portProfile': portProfile,
          'planRam': planRam,
          'ssPort': ssPort,
          'ssPassword': ssPassword,
        },
        lightweight: true,
      );
    }

    final hyPort = ports[1];
    final vlessPort = ports[2];
    final trojanPort = ports[3];
    final vlessRelayPort = ports.length > 4 ? ports[4] : 0;
    final hyPassword = PortProfileAllocator.generatePassword(22);
    final trojanPassword = PortProfileAllocator.generatePassword(22);
    final vlessUuid = _generateUuidV4();
    final realityKeyPair = await _generateRealityKeyPair();
    final vlessShortId = _generateShortId();

    return VultrDeploymentBundle(
      userData: _multiProtocolScript(
        ssPort: ssPort,
        ssPassword: ssPassword,
        hyPort: hyPort,
        hyPassword: hyPassword,
        hyServerName: defaultHysteriaServerName,
        hyMasqueradeUrl: defaultHysteriaMasqueradeUrl,
        vlessPort: vlessPort,
        vlessUuid: vlessUuid,
        vlessPrivateKey: realityKeyPair.privateKey,
        vlessPublicKey: realityKeyPair.publicKey,
        vlessShortId: vlessShortId,
        vlessServerName: defaultVlessServerName,
        vlessRelayPort: vlessRelayPort,
        trojanPort: trojanPort,
        trojanPassword: trojanPassword,
        trojanServerName: defaultTrojanServerName,
      ),
      nodeRecord: {
        'portProfile': portProfile,
        'planRam': planRam,
        'ssPort': ssPort,
        'ssPassword': ssPassword,
        'hyPort': hyPort,
        'hyPassword': hyPassword,
        'hysteriaServerName': defaultHysteriaServerName,
        'vlessPort': vlessPort,
        'vlessUUID': vlessUuid,
        'vlessPublicKey': realityKeyPair.publicKey,
        'vlessShortId': vlessShortId,
        'vlessServerName': defaultVlessServerName,
        if (vlessRelayPort > 0) 'vlessRelayPort': vlessRelayPort,
        'trojanPort': trojanPort,
        'trojanPassword': trojanPassword,
        'trojanServerName': defaultTrojanServerName,
      },
      lightweight: false,
    );
  }

  static bool _isLightweight(int planRam) {
    return planRam > 0 && planRam <= lightweightPlanRamThresholdMb;
  }

  static String _generateUuidV4() {
    final bytes = _randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static String _generateShortId() {
    final bytes = _randomBytes(8);
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<({String privateKey, String publicKey})>
      _generateRealityKeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = (await keyPair.extractPublicKey()).bytes;
    return (
      privateKey: _base64RawUrl(privateKey),
      publicKey: _base64RawUrl(publicKey),
    );
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _base64RawUrl(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _multiProtocolScript({
    required int ssPort,
    required String ssPassword,
    required int hyPort,
    required String hyPassword,
    required String hyServerName,
    required String hyMasqueradeUrl,
    required int vlessPort,
    required String vlessUuid,
    required String vlessPrivateKey,
    required String vlessPublicKey,
    required String vlessShortId,
    required String vlessServerName,
    required int trojanPort,
    required String trojanPassword,
    required String trojanServerName,
    int vlessRelayPort = 0,
  }) {
    var script = _multiProtocolTemplate;
    // The relay block (UFW rule + sing-box config + systemd service) is
    // conditional: only emitted when a relay port is allocated. Older
    // (zero-port) deploys produce the same multi-protocol output as before
    // so we can ship this template change without forcing a re-deploy of
    // every existing node.
    final relayBlock = vlessRelayPort > 0
        ? _vlessRelayBlock(vlessRelayPort, vlessUuid)
        : '';
    final relayUfw = vlessRelayPort > 0
        ? "ufw allow $vlessRelayPort/tcp comment 'VLESS-Relay (CDN)'\n"
        : '';
    final relayServices = vlessRelayPort > 0 ? ' vless-relay-server' : '';
    final replacements = <String, String>{
      'SS_PORT': '$ssPort',
      'SS_PASSWORD': ssPassword,
      'HY_PORT': '$hyPort',
      'HY_PASSWORD': hyPassword,
      'HY_SERVER_NAME': hyServerName,
      'HY_MASQUERADE_URL': hyMasqueradeUrl,
      'VLESS_PORT': '$vlessPort',
      'VLESS_UUID': vlessUuid,
      'VLESS_PRIVATE_KEY': vlessPrivateKey,
      'VLESS_PUBLIC_KEY': vlessPublicKey,
      'VLESS_SHORT_ID': vlessShortId,
      'VLESS_SERVER_NAME': vlessServerName,
      'VLESS_RELAY_BLOCK': relayBlock,
      'VLESS_RELAY_UFW': relayUfw,
      'VLESS_RELAY_SERVICES': relayServices,
      'TROJAN_PORT': '$trojanPort',
      'TROJAN_PASSWORD': trojanPassword,
      'TROJAN_SERVER_NAME': trojanServerName,
      'SINGBOX_VERSION': defaultSingBoxVersion,
    };
    for (final entry in replacements.entries) {
      script = script.replaceAll('{{${entry.key}}}', entry.value);
    }
    return script;
  }

  // Mirrors the Go-side vlessRelayBlock in bridge/cloud/deploy/deploy.go so
  // mobile-deployed nodes can be CDN-fronted without re-deploying through
  // desktop. Plain VLESS over TCP (no Reality, no TLS — Cloudflare's edge
  // terminates TLS, the Worker dials this port, the VPS terminates the
  // inner VLESS auth on the same UUID as the Reality endpoint).
  static String _vlessRelayBlock(int relayPort, String uuid) => '''
cat > /etc/privatedeploy/vless/relay.json <<RELAYEOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-relay-in",
    "listen": "::",
    "listen_port": $relayPort,
    "users": [{ "uuid": "$uuid" }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
RELAYEOF
chmod 600 /etc/privatedeploy/vless/relay.json
chown privatedeploy:privatedeploy /etc/privatedeploy/vless/relay.json

cat > /etc/systemd/system/vless-relay-server.service <<'RELAYSERVICE'
[Unit]
Description=VLESS plain relay (sing-box, for CDN front)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/privatedeploy/vless/relay.json
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
RELAYSERVICE
''';
}

const String _multiProtocolTemplate = r'''#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077

LOGFILE="/var/log/privatedeploy-init.log"
exec > >(tee -a "$LOGFILE") 2>&1
trap 'chmod 600 "$LOGFILE" 2>/dev/null' EXIT

echo "=== PrivateDeploy Multi-Protocol Init Started at $(date) ==="

apt-get update -qq
apt-get install -y docker.io ufw iptables openssl curl ca-certificates net-tools

systemctl enable docker
systemctl start docker
sleep 2

useradd --system --no-create-home --shell /usr/sbin/nologin privatedeploy 2>/dev/null || true

mkdir -p /etc/privatedeploy/{hysteria,trojan,vless}
chmod 700 /etc/privatedeploy /etc/privatedeploy/hysteria /etc/privatedeploy/trojan /etc/privatedeploy/vless

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

generate_cert /etc/privatedeploy/hysteria/cert.pem /etc/privatedeploy/hysteria/key.pem {{HY_SERVER_NAME}}
generate_cert /etc/privatedeploy/trojan/cert.pem /etc/privatedeploy/trojan/key.pem {{TROJAN_SERVER_NAME}}

ufw --force disable || true
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow {{SS_PORT}}/tcp comment 'Shadowsocks-TCP'
ufw allow {{SS_PORT}}/udp comment 'Shadowsocks-UDP'
ufw allow {{HY_PORT}}/udp comment 'Hysteria2'
ufw allow {{VLESS_PORT}}/tcp comment 'VLESS-Reality'
{{VLESS_RELAY_UFW}}ufw allow {{TROJAN_PORT}}/tcp comment 'Trojan'
echo "y" | ufw enable

docker rm -f ss-server >/dev/null 2>&1 || true
docker pull --quiet teddysun/shadowsocks-libev || true
docker run -d --name ss-server --restart=always \
  -p {{SS_PORT}}:{{SS_PORT}}/tcp -p {{SS_PORT}}:{{SS_PORT}}/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p {{SS_PORT}} -k "{{SS_PASSWORD}}" -m aes-256-gcm

mkdir -p /tmp/privatedeploy
curl -fsSLo /tmp/privatedeploy/singbox.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v{{SINGBOX_VERSION}}/sing-box-{{SINGBOX_VERSION}}-linux-amd64.tar.gz"
tar -xzf /tmp/privatedeploy/singbox.tar.gz -C /tmp/privatedeploy
find /tmp/privatedeploy -name "sing-box" -type f -executable -exec mv {} /usr/local/bin/sing-box \;
chmod +x /usr/local/bin/sing-box

cat > /etc/privatedeploy/hysteria/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": "::",
    "listen_port": {{HY_PORT}},
    "up_mbps": 100,
    "down_mbps": 100,
    "users": [{
      "password": "{{HY_PASSWORD}}"
    }],
    "masquerade": "{{HY_MASQUERADE_URL}}",
    "tls": {
      "enabled": true,
      "server_name": "{{HY_SERVER_NAME}}",
      "certificate_path": "/etc/privatedeploy/hysteria/cert.pem",
      "key_path": "/etc/privatedeploy/hysteria/key.pem"
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
EOF
chmod 600 /etc/privatedeploy/hysteria/config.json

cat > /etc/privatedeploy/vless/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": {{VLESS_PORT}},
    "users": [{
      "uuid": "{{VLESS_UUID}}",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "{{VLESS_SERVER_NAME}}",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "{{VLESS_SERVER_NAME}}",
          "server_port": 443
        },
        "private_key": "{{VLESS_PRIVATE_KEY}}",
        "short_id": ["{{VLESS_SHORT_ID}}"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
EOF
chmod 600 /etc/privatedeploy/vless/config.json

cat > /etc/privatedeploy/vless/reality.txt <<EOF
PublicKey: {{VLESS_PUBLIC_KEY}}
ShortID: {{VLESS_SHORT_ID}}
EOF
chmod 600 /etc/privatedeploy/vless/reality.txt

{{VLESS_RELAY_BLOCK}}

cat > /etc/privatedeploy/trojan/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "trojan",
    "tag": "trojan-in",
    "listen": "::",
    "listen_port": {{TROJAN_PORT}},
    "users": [{
      "password": "{{TROJAN_PASSWORD}}"
    }],
    "tls": {
      "enabled": true,
      "server_name": "{{TROJAN_SERVER_NAME}}",
      "key_path": "/etc/privatedeploy/trojan/key.pem",
      "certificate_path": "/etc/privatedeploy/trojan/cert.pem"
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
EOF
chmod 600 /etc/privatedeploy/trojan/config.json

chown -R privatedeploy:privatedeploy /etc/privatedeploy

cat > /etc/systemd/system/hysteria-server.service <<'EOF'
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
EOF

cat > /etc/systemd/system/vless-server.service <<'EOF'
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
EOF

cat > /etc/systemd/system/trojan-server.service <<'EOF'
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
EOF

systemctl daemon-reload
systemctl enable hysteria-server vless-server trojan-server{{VLESS_RELAY_SERVICES}}
systemctl restart hysteria-server vless-server trojan-server{{VLESS_RELAY_SERVICES}}

sleep 5
echo ""
echo "=== PrivateDeploy Multi-Protocol Init Completed at $(date) ==="
echo "Listening ports:"
ss -tlnup | grep -E ':{{SS_PORT}} |:{{HY_PORT}} |:{{VLESS_PORT}} |:{{TROJAN_PORT}} ' || true
''';
