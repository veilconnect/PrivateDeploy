import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import '../../shared/utils/logger.dart';

class VultrApi {
  static const String _baseUrl = 'https://api.vultr.com/v2';
  final String apiKey;
  late final Dio _dio;

  VultrApi(this.apiKey) {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
    ));
  }

  /// List all instances
  Future<List<VultrInstance>> listInstances() async {
    try {
      final resp = await _dio.get('/instances');
      final data = resp.data as Map<String, dynamic>;
      final instances = data['instances'] as List? ?? [];
      return instances
          .map((i) => VultrInstance.fromJson(i as Map<String, dynamic>))
          .toList();
    } catch (e) {
      AppLogger.error('[VultrApi] listInstances error', e);
      rethrow;
    }
  }

  /// Get a single instance
  Future<VultrInstance> getInstance(String id) async {
    final resp = await _dio.get('/instances/$id');
    return VultrInstance.fromJson(resp.data['instance']);
  }

  /// List available regions
  Future<List<VultrRegion>> listRegions() async {
    final resp = await _dio.get('/regions');
    final regions = resp.data['regions'] as List? ?? [];
    return regions
        .map((r) => VultrRegion.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// List available plans
  Future<List<VultrPlan>> listPlans() async {
    final resp = await _dio.get('/plans');
    final plans = resp.data['plans'] as List? ?? [];
    return plans
        .map((p) => VultrPlan.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Create a new instance with multi-protocol proxy deployment
  Future<VultrInstance> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    // Generate credentials
    final rng = Random.secure();
    final ssPort = 20000 + rng.nextInt(30000);
    final hyPort = ssPort + 1;
    final vlessPort = ssPort + 2;
    final trojanPort = ssPort + 3;

    final ssPassword = _randomPassword(rng);
    final hyPassword = _randomPassword(rng);
    final trojanPassword = _randomPassword(rng);
    final vlessUuid = _generateUuid(rng);

    // Build deployment script
    final script = _buildDeployScript(
      ssPort: ssPort,
      hyPort: hyPort,
      vlessPort: vlessPort,
      trojanPort: trojanPort,
      ssPassword: ssPassword,
      hyPassword: hyPassword,
      trojanPassword: trojanPassword,
      vlessUuid: vlessUuid,
    );

    final userData = base64Encode(utf8.encode(script));

    // Find a valid OS ID (Debian 12)
    const osId = 2136; // Debian 12 x64

    final resp = await _dio.post('/instances', data: {
      'region': region,
      'plan': plan,
      'label': label,
      'os_id': osId,
      'enable_ipv6': true,
      'user_data': userData,
    });

    final instance = VultrInstance.fromJson(resp.data['instance']);

    // Store node info locally
    instance.nodeInfo = NodeInfo(
      ssPort: ssPort,
      ssPassword: ssPassword,
      hyPort: hyPort,
      hyPassword: hyPassword,
      vlessPort: vlessPort,
      vlessUuid: vlessUuid,
      trojanPort: trojanPort,
      trojanPassword: trojanPassword,
    );

    return instance;
  }

  /// Delete an instance
  Future<void> deleteInstance(String id) async {
    await _dio.delete('/instances/$id');
  }

  /// Verify API key is valid
  Future<bool> verifyApiKey() async {
    try {
      await _dio.get('/account');
      return true;
    } catch (_) {
      return false;
    }
  }

  String _randomPassword(Random rng) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(22, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  String _generateUuid(Random rng) {
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  String _buildDeployScript({
    required int ssPort,
    required int hyPort,
    required int vlessPort,
    required int trojanPort,
    required String ssPassword,
    required String hyPassword,
    required String trojanPassword,
    required String vlessUuid,
  }) {
    return '''#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# Update system
apt-get update -qq && apt-get upgrade -y -qq

# Install dependencies
apt-get install -y -qq docker.io ufw curl openssl
systemctl enable docker && systemctl start docker

# Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow $ssPort/tcp
ufw allow $ssPort/udp
ufw allow $hyPort/udp
ufw allow $vlessPort/tcp
ufw allow $trojanPort/tcp
ufw --force enable

# Generate TLS certs
mkdir -p /etc/privatedeploy/certs
openssl ecparam -genkey -name prime256v1 -out /etc/privatedeploy/certs/key.pem 2>/dev/null
openssl req -new -x509 -days 30 -key /etc/privatedeploy/certs/key.pem -out /etc/privatedeploy/certs/cert.pem -subj "/CN=cloudflare.com" 2>/dev/null

# Shadowsocks via Docker
docker pull teddysun/shadowsocks-libev:latest
docker run -d --name ss-server --restart=always \\
  -p $ssPort:$ssPort -p $ssPort:$ssPort/udp \\
  -e SERVER_PORT=$ssPort \\
  -e PASSWORD=$ssPassword \\
  -e METHOD=aes-256-gcm \\
  teddysun/shadowsocks-libev

# Install sing-box
SINGBOX_VERSION="1.11.0"
ARCH=\$(uname -m)
case \$ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
esac
curl -sLo /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v\${SINGBOX_VERSION}/sing-box-\${SINGBOX_VERSION}-linux-\${ARCH}.tar.gz"
tar -xzf /tmp/sing-box.tar.gz -C /tmp/
cp /tmp/sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# Hysteria2 config
mkdir -p /etc/privatedeploy/hysteria
cat > /etc/privatedeploy/hysteria/config.json << 'HYSTERIA_EOF'
{
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": $hyPort,
    "users": [{"password": "$hyPassword"}],
    "tls": {
      "enabled": true,
      "certificate_path": "/etc/privatedeploy/certs/cert.pem",
      "key_path": "/etc/privatedeploy/certs/key.pem"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
HYSTERIA_EOF

# VLESS Reality config
mkdir -p /etc/privatedeploy/vless
cat > /etc/privatedeploy/vless/config.json << 'VLESS_EOF'
{
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": $vlessPort,
    "users": [{"uuid": "$vlessUuid", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "www.microsoft.com", "server_port": 443},
        "private_key": "",
        "short_id": ["0123456789abcdef"]
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
VLESS_EOF

# Trojan config
mkdir -p /etc/privatedeploy/trojan
cat > /etc/privatedeploy/trojan/config.json << 'TROJAN_EOF'
{
  "inbounds": [{
    "type": "trojan",
    "listen": "::",
    "listen_port": $trojanPort,
    "users": [{"password": "$trojanPassword"}],
    "tls": {
      "enabled": true,
      "certificate_path": "/etc/privatedeploy/certs/cert.pem",
      "key_path": "/etc/privatedeploy/certs/key.pem"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
TROJAN_EOF

# Systemd services
for svc in hysteria vless trojan; do
cat > /etc/systemd/system/\${svc}-server.service << SVC_EOF
[Unit]
Description=\${svc} server
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/privatedeploy/\${svc}/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF
done

systemctl daemon-reload
systemctl enable --now hysteria-server vless-server trojan-server

echo "PrivateDeploy deployment complete"
''';
  }
}

class VultrInstance {
  final String id;
  final String label;
  final String status;
  final String region;
  final String plan;
  final String? mainIp;
  final String? v6MainIp;
  final DateTime? dateCreated;
  NodeInfo? nodeInfo;

  VultrInstance({
    required this.id,
    required this.label,
    required this.status,
    required this.region,
    required this.plan,
    this.mainIp,
    this.v6MainIp,
    this.dateCreated,
    this.nodeInfo,
  });

  factory VultrInstance.fromJson(Map<String, dynamic> json) {
    return VultrInstance(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      status: json['status']?.toString() ?? 'unknown',
      region: json['region']?.toString() ?? '',
      plan: json['plan']?.toString() ?? '',
      mainIp: json['main_ip']?.toString(),
      v6MainIp: json['v6_main_ip']?.toString(),
      dateCreated: json['date_created'] != null
          ? DateTime.tryParse(json['date_created'].toString())
          : null,
    );
  }

  bool get isActive => status == 'active';
  bool get hasIp => mainIp != null && mainIp!.isNotEmpty && mainIp != '0.0.0.0';
}

class VultrRegion {
  final String id;
  final String city;
  final String country;
  final String continent;

  VultrRegion({
    required this.id,
    required this.city,
    required this.country,
    required this.continent,
  });

  factory VultrRegion.fromJson(Map<String, dynamic> json) {
    return VultrRegion(
      id: json['id']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      country: json['country']?.toString() ?? '',
      continent: json['continent']?.toString() ?? '',
    );
  }

  String get displayName => '$city, $country';
}

class VultrPlan {
  final String id;
  final int ram;
  final int vcpuCount;
  final int disk;
  final double monthlyCost;
  final List<String> locations;

  VultrPlan({
    required this.id,
    required this.ram,
    required this.vcpuCount,
    required this.disk,
    required this.monthlyCost,
    required this.locations,
  });

  factory VultrPlan.fromJson(Map<String, dynamic> json) {
    return VultrPlan(
      id: json['id']?.toString() ?? '',
      ram: (json['ram'] as num?)?.toInt() ?? 0,
      vcpuCount: (json['vcpu_count'] as num?)?.toInt() ?? 0,
      disk: (json['disk'] as num?)?.toInt() ?? 0,
      monthlyCost: (json['monthly_cost'] as num?)?.toDouble() ?? 0,
      locations: (json['locations'] as List?)?.map((l) => l.toString()).toList() ?? [],
    );
  }

  String get displayName =>
      '${vcpuCount}vCPU / ${ram >= 1024 ? '${ram ~/ 1024}GB' : '${ram}MB'} / ${disk}GB - \$${monthlyCost.toStringAsFixed(0)}/mo';
}

class NodeInfo {
  final int ssPort;
  final String ssPassword;
  final int hyPort;
  final String hyPassword;
  final int vlessPort;
  final String vlessUuid;
  final int trojanPort;
  final String trojanPassword;

  NodeInfo({
    required this.ssPort,
    required this.ssPassword,
    required this.hyPort,
    required this.hyPassword,
    required this.vlessPort,
    required this.vlessUuid,
    required this.trojanPort,
    required this.trojanPassword,
  });

  Map<String, dynamic> toJson() => {
    'ss_port': ssPort,
    'ss_password': ssPassword,
    'hy_port': hyPort,
    'hy_password': hyPassword,
    'vless_port': vlessPort,
    'vless_uuid': vlessUuid,
    'trojan_port': trojanPort,
    'trojan_password': trojanPassword,
  };

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
    ssPort: json['ss_port'] ?? 0,
    ssPassword: json['ss_password'] ?? '',
    hyPort: json['hy_port'] ?? 0,
    hyPassword: json['hy_password'] ?? '',
    vlessPort: json['vless_port'] ?? 0,
    vlessUuid: json['vless_uuid'] ?? '',
    trojanPort: json['trojan_port'] ?? 0,
    trojanPassword: json['trojan_password'] ?? '',
  );
}
