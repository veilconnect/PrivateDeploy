import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vultr_client.dart';

const int lightweightPlanRamThresholdMb = 600;
const String defaultSingBoxVersion = '1.12.12';
// Fallback if the primary download fails. Kept in lockstep with the desktop
// bridge (bridge/cloud/deploy/policy.go) so both ends deploy the same stack.
const String defaultSingBoxFallbackVersion = '1.11.0';
// Pinned SHA-256 of the linux-amd64 sing-box release tarballs shipped by
// default, verified against the upstream GitHub release assets. Kept in lockstep
// with bridge/cloud/deploy/policy.go (singBoxKnownSHA256). The deploy script
// integrity-checks the download against these (sing-box publishes no per-asset
// .sha256sum file, so the pin is the trust anchor); a version with no entry
// degrades to install-without-offline-verification rather than blocking.
const Map<String, String> singBoxKnownSha256 = {
  '1.12.12': '7c103cb2f9a7dc54cb82962043596718ed27989a478d6405f0939a9b775f889f',
  '1.11.0': 'eff0237951bfbd2381be36f114e419f10d3ed57dbf929f680e4cc9f57e319d64',
};

/// Returns the pinned linux-amd64 tarball SHA-256 for [version], or '' when
/// none is pinned. A leading 'v' and surrounding whitespace are tolerated.
String singBoxSha256(String version) =>
    singBoxKnownSha256[version.trim().replaceFirst(RegExp(r'^v'), '')] ?? '';

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
    final relayBlock =
        vlessRelayPort > 0 ? _vlessRelayBlock(vlessRelayPort, vlessUuid) : '';
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
      'SINGBOX_FALLBACK_VERSION': defaultSingBoxFallbackVersion,
      'SINGBOX_SHA256': singBoxSha256(defaultSingBoxVersion),
      'SINGBOX_FALLBACK_SHA256': singBoxSha256(defaultSingBoxFallbackVersion),
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
apt-get install -y docker.io ufw iptables openssl curl ca-certificates net-tools fail2ban

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
ufw logging on
ufw default deny incoming
ufw default allow outgoing
# Rate-limit SSH (ufw 'limit' drops sources with too many recent connections)
# to blunt brute-force attempts while keeping the port reachable for the owner.
ufw limit 22/tcp comment 'SSH (rate-limited)'
ufw allow {{SS_PORT}}/tcp comment 'Shadowsocks-TCP'
ufw allow {{SS_PORT}}/udp comment 'Shadowsocks-UDP'
ufw allow {{HY_PORT}}/udp comment 'Hysteria2'
ufw allow {{VLESS_PORT}}/tcp comment 'VLESS-Reality'
{{VLESS_RELAY_UFW}}ufw allow {{TROJAN_PORT}}/tcp comment 'Trojan'
echo "y" | ufw enable

# Harden the SSH daemon. Password auth is kept because the cloud provider's
# auto-generated root password is the owner's only credential on these boxes;
# disabling it would lock the owner out. Everything else is tightened, and
# fail2ban bans repeat offenders.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-privatedeploy.conf <<'SSHD_EOF'
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
SSHD_EOF
chmod 600 /etc/ssh/sshd_config.d/99-privatedeploy.conf
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

docker rm -f ss-server >/dev/null 2>&1 || true
docker pull --quiet teddysun/shadowsocks-libev || true
docker run -d --name ss-server --restart=always \
  -p {{SS_PORT}}:{{SS_PORT}}/tcp -p {{SS_PORT}}:{{SS_PORT}}/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p {{SS_PORT}} -k "{{SS_PASSWORD}}" -m aes-256-gcm

SINGBOX_VERSION="{{SINGBOX_VERSION}}"
SINGBOX_FALLBACK_VERSION="{{SINGBOX_FALLBACK_VERSION}}"
SINGBOX_SHA256="{{SINGBOX_SHA256}}"
SINGBOX_FALLBACK_SHA256="{{SINGBOX_FALLBACK_SHA256}}"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
FALLBACK_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_FALLBACK_VERSION}/sing-box-${SINGBOX_FALLBACK_VERSION}-linux-amd64.tar.gz"

mkdir -p /tmp/privatedeploy
# Expected hash for whichever version actually downloads (reset in the fallback path).
EXPECTED_SHA256="$SINGBOX_SHA256"

# verify_checksum compares the downloaded tarball against a SHA-256 pinned in the
# app source (verified against the upstream GitHub release). sing-box publishes
# no per-asset .sha256sum file, and re-fetching a hash from the same origin would
# add no supply-chain protection over TLS, so the pin is the trust anchor. An
# empty pin (a version we have no hash for) degrades to a warning.
verify_checksum() {
  local file="$1" expected="$2"
  if [ -z "$expected" ]; then
    echo "[WARN] No pinned checksum for this sing-box version; skipping verification" >&2
    return 0
  fi
  local actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$actual" = "$expected" ]; then
    echo "[OK] sing-box checksum verified"
    return 0
  fi
  echo "[WARN] sing-box checksum mismatch! expected=${expected} actual=${actual}" >&2
  return 1
}

# Skip download if sing-box is already installed.
if command -v sing-box >/dev/null 2>&1; then
  echo "[OK] sing-box already installed: $(sing-box version 2>/dev/null | head -1)"
elif ! curl -fsSLo /tmp/privatedeploy/singbox.tar.gz "$SINGBOX_URL"; then
  if [ -n "$SINGBOX_FALLBACK_VERSION" ] && [ "$SINGBOX_FALLBACK_VERSION" != "$SINGBOX_VERSION" ]; then
    echo "[WARN] Failed to download sing-box ${SINGBOX_VERSION}, attempting fallback ${SINGBOX_FALLBACK_VERSION}..." >&2
    if ! curl -fsSLo /tmp/privatedeploy/singbox.tar.gz "$FALLBACK_URL"; then
      echo "[ERROR] Could not download sing-box binaries. Skipping VLESS/Trojan/Hysteria deployment." >&2
      SKIP_SINGBOX=1
    else
      SINGBOX_VERSION="$SINGBOX_FALLBACK_VERSION"
      EXPECTED_SHA256="$SINGBOX_FALLBACK_SHA256"
    fi
  else
    echo "[ERROR] Could not download sing-box ${SINGBOX_VERSION} and no valid fallback is configured. Skipping VLESS/Trojan/Hysteria deployment." >&2
    SKIP_SINGBOX=1
  fi
fi

if [ "${SKIP_SINGBOX:-0}" -ne 1 ] && [ -f /tmp/privatedeploy/singbox.tar.gz ]; then
  if ! verify_checksum /tmp/privatedeploy/singbox.tar.gz "$EXPECTED_SHA256"; then
    echo "[ERROR] sing-box integrity check failed. Aborting sing-box deployment." >&2
    SKIP_SINGBOX=1
  fi
fi

if [ "${SKIP_SINGBOX:-0}" -ne 1 ] && [ -f /tmp/privatedeploy/singbox.tar.gz ]; then
  tar -xzf /tmp/privatedeploy/singbox.tar.gz -C /tmp/privatedeploy
  find /tmp/privatedeploy -name "sing-box" -type f -executable -exec mv {} /usr/local/bin/sing-box \;
  chmod +x /usr/local/bin/sing-box
fi

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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
# Only bring up the sing-box services if sing-box actually installed. If its
# download/checksum failed, Shadowsocks still serves traffic rather than the
# whole deploy aborting.
if [ "${SKIP_SINGBOX:-0}" -ne 1 ] && command -v sing-box >/dev/null 2>&1; then
  systemctl enable hysteria-server vless-server trojan-server{{VLESS_RELAY_SERVICES}}
  systemctl restart hysteria-server vless-server trojan-server{{VLESS_RELAY_SERVICES}}
else
  echo "[WARN] sing-box not installed; skipping Hysteria2/VLESS/Trojan services. Shadowsocks remains active." >&2
fi

sleep 5
echo ""
echo "=== PrivateDeploy Multi-Protocol Init Completed at $(date) ==="
echo "Listening ports:"
ss -tlnup | grep -E ':{{SS_PORT}} |:{{HY_PORT}} |:{{VLESS_PORT}} |:{{TROJAN_PORT}} ' || true
''';
