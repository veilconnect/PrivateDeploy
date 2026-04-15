import 'cloud_models.dart';
import 'cloud_provider_id.dart';
import 'vultr_client.dart';

class VultrNodeRecord {
  final CloudProviderId provider;
  final String instanceId;
  final String label;
  final String region;
  final String plan;
  final int osId;
  final int ssPort;
  final String ssPassword;
  final int hyPort;
  final String hyPassword;
  final String hyServerName;
  final int vlessPort;
  final String vlessUuid;
  final String vlessPublicKey;
  final String vlessShortId;
  final String vlessServerName;
  final int trojanPort;
  final String trojanPassword;
  final String trojanServerName;
  final String ipv4;
  final String ipv6;
  final String createdAt;
  final String portProfile;
  final int planRam;

  VultrNodeRecord({
    required this.instanceId,
    this.provider = CloudProviderId.vultr,
    this.label = '',
    this.region = '',
    this.plan = '',
    this.osId = 0,
    this.ssPort = 0,
    this.ssPassword = '',
    this.hyPort = 0,
    this.hyPassword = '',
    this.hyServerName = '',
    this.vlessPort = 0,
    this.vlessUuid = '',
    this.vlessPublicKey = '',
    this.vlessShortId = '',
    this.vlessServerName = '',
    this.trojanPort = 0,
    this.trojanPassword = '',
    this.trojanServerName = '',
    this.ipv4 = '',
    this.ipv6 = '',
    this.createdAt = '',
    this.portProfile = PortProfileAllocator.randomProfile,
    this.planRam = 0,
  });

  bool get isUsable => ssPort > 0 && ssPassword.isNotEmpty;

  CloudInstance toCloudInstance() {
    return CloudInstance(
      id: instanceId,
      provider: provider.id,
      label: label,
      status: isUsable ? 'active' : 'unknown',
      region: region,
      plan: plan,
      ipv4: _stringOrNull(ipv4),
      ipv6: _stringOrNull(ipv6),
      createdAt: _parseTime(createdAt),
      nodeInfo: NodeInfo(
        ssPort: ssPort,
        ssPassword: ssPassword,
        hyPort: hyPort,
        hyPassword: hyPassword,
        hyServerName: hyServerName,
        hyInsecure: true,
        vlessPort: vlessPort,
        vlessUuid: vlessUuid,
        vlessPublicKey: vlessPublicKey,
        vlessShortId: vlessShortId,
        vlessServerName: vlessServerName,
        trojanPort: trojanPort,
        trojanPassword: trojanPassword,
        trojanServerName: trojanServerName,
        trojanInsecure: true,
      ),
    );
  }

  VultrNodeRecord copyWithJson(Map<String, dynamic> values) {
    return VultrNodeRecord(
      instanceId: instanceId,
      provider: provider,
      label: (values['label'] ?? label).toString(),
      region: (values['region'] ?? region).toString(),
      plan: (values['plan'] ?? plan).toString(),
      osId: _toInt(values['osId'], defaultValue: osId),
      ssPort: _toInt(values['ssPort'], defaultValue: ssPort),
      ssPassword: (values['ssPassword'] ?? ssPassword).toString(),
      hyPort: _toInt(values['hyPort'], defaultValue: hyPort),
      hyPassword: (values['hyPassword'] ?? hyPassword).toString(),
      hyServerName: (values['hysteriaServerName'] ?? hyServerName).toString(),
      vlessPort: _toInt(values['vlessPort'], defaultValue: vlessPort),
      vlessUuid: (values['vlessUUID'] ?? vlessUuid).toString(),
      vlessPublicKey: (values['vlessPublicKey'] ?? vlessPublicKey).toString(),
      vlessShortId: (values['vlessShortId'] ?? vlessShortId).toString(),
      vlessServerName:
          (values['vlessServerName'] ?? vlessServerName).toString(),
      trojanPort: _toInt(values['trojanPort'], defaultValue: trojanPort),
      trojanPassword: (values['trojanPassword'] ?? trojanPassword).toString(),
      trojanServerName:
          (values['trojanServerName'] ?? trojanServerName).toString(),
      ipv4: (values['ipv4'] ?? ipv4).toString(),
      ipv6: (values['ipv6'] ?? ipv6).toString(),
      createdAt: (values['createdAt'] ?? createdAt).toString(),
      portProfile: (values['portProfile'] ?? portProfile).toString(),
      planRam: _toInt(values['planRam'], defaultValue: planRam),
    );
  }

  Map<String, dynamic> toMergeableJson() {
    final result = <String, dynamic>{
      'id': instanceId,
      'provider': provider.id,
      'ssPort': ssPort,
      'ssPassword': ssPassword,
      'hysteriaPort': hyPort,
      'hysteriaPassword': hyPassword,
      'hysteriaServerName': hyServerName,
      'vlessPort': vlessPort,
      'vlessUUID': vlessUuid,
      'vlessPublicKey': vlessPublicKey,
      'vlessShortId': vlessShortId,
      'vlessServerName': vlessServerName,
      'trojanPort': trojanPort,
      'trojanPassword': trojanPassword,
      'trojanServerName': trojanServerName,
    };

    if (label.isNotEmpty) {
      result['label'] = label;
    }
    if (region.isNotEmpty) {
      result['region'] = region;
    }
    if (plan.isNotEmpty) {
      result['plan'] = plan;
    }
    if (ipv4.isNotEmpty && ipv4 != '0.0.0.0') {
      result['main_ip'] = ipv4;
    }
    if (ipv6.isNotEmpty) {
      result['v6_main_ip'] = ipv6;
    }
    if (createdAt.isNotEmpty) {
      result['createdAt'] = createdAt;
    }

    return result;
  }

  Map<String, dynamic> toJson() => {
        'instanceId': instanceId,
        'provider': provider.id,
        'label': label,
        'region': region,
        'plan': plan,
        'osId': osId,
        'ssPort': ssPort,
        'ssPassword': ssPassword,
        'hyPort': hyPort,
        'hyPassword': hyPassword,
        'hysteriaServerName': hyServerName,
        'vlessPort': vlessPort,
        'vlessUUID': vlessUuid,
        'vlessPublicKey': vlessPublicKey,
        'vlessShortId': vlessShortId,
        'vlessServerName': vlessServerName,
        'trojanPort': trojanPort,
        'trojanPassword': trojanPassword,
        'trojanServerName': trojanServerName,
        'ipv4': ipv4,
        'ipv6': ipv6,
        'createdAt': createdAt,
        'portProfile': portProfile,
        'planRam': planRam,
      };

  static VultrNodeRecord fromJson(
    String instanceId,
    Map<String, dynamic> json,
  ) {
    return VultrNodeRecord(
      instanceId: instanceId,
      provider: CloudProviderId.parseOrVultr(json['provider']?.toString()),
      label: (json['label'] ?? '').toString(),
      region: (json['region'] ?? '').toString(),
      plan: (json['plan'] ?? '').toString(),
      osId: _toInt(json['osId']),
      ssPort: _toInt(json['ssPort']),
      ssPassword: (json['ssPassword'] ?? '').toString(),
      hyPort: _toInt(json['hyPort']),
      hyPassword: (json['hyPassword'] ?? '').toString(),
      hyServerName: (json['hysteriaServerName'] ?? '').toString(),
      vlessPort: _toInt(json['vlessPort']),
      vlessUuid: (json['vlessUUID'] ?? '').toString(),
      vlessPublicKey: (json['vlessPublicKey'] ?? '').toString(),
      vlessShortId: (json['vlessShortId'] ?? '').toString(),
      vlessServerName: (json['vlessServerName'] ?? '').toString(),
      trojanPort: _toInt(json['trojanPort']),
      trojanPassword: (json['trojanPassword'] ?? '').toString(),
      trojanServerName: (json['trojanServerName'] ?? '').toString(),
      ipv4: (json['ipv4'] ?? '').toString(),
      ipv6: (json['ipv6'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      portProfile: (json['portProfile'] ?? PortProfileAllocator.randomProfile)
          .toString(),
      planRam: _toInt(json['planRam']),
    );
  }

  static int _toInt(dynamic value, {int defaultValue = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? defaultValue;
    }
    return defaultValue;
  }

  static String? _stringOrNull(String value) {
    if (value.isEmpty) {
      return null;
    }
    return value;
  }

  static DateTime? _parseTime(String value) {
    if (value.isEmpty) {
      return null;
    }
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }
}
