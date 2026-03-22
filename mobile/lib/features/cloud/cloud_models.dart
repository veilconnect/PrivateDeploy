class CloudInstance {
  final String id;
  final String provider;
  final String label;
  final String status;
  final String region;
  final String plan;
  final String? ipv4;
  final String? ipv6;
  final DateTime? createdAt;
  final NodeInfo? nodeInfo;

  CloudInstance({
    required this.id,
    required this.provider,
    required this.label,
    required this.status,
    required this.region,
    required this.plan,
    this.ipv4,
    this.ipv6,
    this.createdAt,
    this.nodeInfo,
  });

  factory CloudInstance.fromJson(Map<String, dynamic> json) {
    final nodeInfo = NodeInfo.fromInstanceJson(json);
    return CloudInstance(
      id: _stringValue(json, const ['id']),
      provider: _stringValue(json, const ['provider'], fallback: 'vultr'),
      label: _stringValue(json, const ['label']),
      status: _stringValue(json, const ['status'], fallback: 'unknown'),
      region: _stringValue(json, const ['region']),
      plan: _stringValue(json, const ['plan']),
      ipv4: _optionalStringValue(json, const ['ipv4', 'main_ip']),
      ipv6: _optionalStringValue(json, const ['ipv6', 'v6_main_ip']),
      createdAt: _parseDate(json['createdAt'] ?? json['date_created']),
      nodeInfo: nodeInfo.isUsable ? nodeInfo : null,
    );
  }

  bool get isActive => status == 'active';
  bool get hasIp => ipv4 != null && ipv4!.isNotEmpty && ipv4 != '0.0.0.0';
}

class CloudRegion {
  final String id;
  final String city;
  final String country;
  final String continent;

  CloudRegion({
    required this.id,
    required this.city,
    required this.country,
    required this.continent,
  });

  factory CloudRegion.fromJson(Map<String, dynamic> json) {
    return CloudRegion(
      id: _stringValue(json, const ['id']),
      city: _stringValue(json, const ['city']),
      country: _stringValue(json, const ['country']),
      continent: _stringValue(json, const ['continent']),
    );
  }

  String get displayName => '$city, $country';
}

class CloudPlan {
  final String id;
  final int ram;
  final int vcpuCount;
  final int disk;
  final double monthlyCost;
  final List<String> locations;

  CloudPlan({
    required this.id,
    required this.ram,
    required this.vcpuCount,
    required this.disk,
    required this.monthlyCost,
    required this.locations,
  });

  factory CloudPlan.fromJson(Map<String, dynamic> json) {
    return CloudPlan(
      id: _stringValue(json, const ['id']),
      ram: _intValue(json, const ['ram']),
      vcpuCount: _intValue(json, const ['vcpus', 'vcpu_count']),
      disk: _intValue(json, const ['disk']),
      monthlyCost: _doubleValue(json, const ['monthlyCost', 'monthly_cost']),
      locations: _listValue(json, const ['locations']),
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
  final String hyServerName;
  final bool? hyInsecure;
  final int vlessPort;
  final String vlessUuid;
  final String vlessPublicKey;
  final String vlessShortId;
  final String vlessServerName;
  final int trojanPort;
  final String trojanPassword;
  final String trojanServerName;
  final bool? trojanInsecure;

  const NodeInfo({
    required this.ssPort,
    required this.ssPassword,
    required this.hyPort,
    required this.hyPassword,
    required this.hyServerName,
    required this.hyInsecure,
    required this.vlessPort,
    required this.vlessUuid,
    required this.vlessPublicKey,
    required this.vlessShortId,
    required this.vlessServerName,
    required this.trojanPort,
    required this.trojanPassword,
    required this.trojanServerName,
    required this.trojanInsecure,
  });

  factory NodeInfo.fromInstanceJson(Map<String, dynamic> json) {
    return NodeInfo(
      ssPort: _intValue(json, const ['ssPort', 'ss_port']),
      ssPassword: _stringValue(json, const ['ssPassword', 'ss_password']),
      hyPort: _intValue(json, const ['hysteriaPort', 'hy_port']),
      hyPassword: _stringValue(json, const ['hysteriaPassword', 'hy_password']),
      hyServerName:
          _stringValue(json, const ['hysteriaServerName', 'hy_server_name']),
      hyInsecure: _boolValue(json, const ['hysteriaInsecure', 'hy_insecure']),
      vlessPort: _intValue(json, const ['vlessPort', 'vless_port']),
      vlessUuid:
          _stringValue(json, const ['vlessUUID', 'vlessUuid', 'vless_uuid']),
      vlessPublicKey:
          _stringValue(json, const ['vlessPublicKey', 'vless_public_key']),
      vlessShortId:
          _stringValue(json, const ['vlessShortId', 'vless_short_id']),
      vlessServerName:
          _stringValue(json, const ['vlessServerName', 'vless_server_name']),
      trojanPort: _intValue(json, const ['trojanPort', 'trojan_port']),
      trojanPassword:
          _stringValue(json, const ['trojanPassword', 'trojan_password']),
      trojanServerName:
          _stringValue(json, const ['trojanServerName', 'trojan_server_name']),
      trojanInsecure:
          _boolValue(json, const ['trojanInsecure', 'trojan_insecure']),
    );
  }

  bool get isUsable =>
      (ssPort > 0 && ssPassword.isNotEmpty) ||
      (hyPort > 0 && hyPassword.isNotEmpty) ||
      (vlessPort > 0 && vlessUuid.isNotEmpty) ||
      (trojanPort > 0 && trojanPassword.isNotEmpty);
}

String _stringValue(
  Map<String, dynamic> json,
  List<String> keys, {
  String fallback = '',
}) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) {
      continue;
    }
    final text = value.toString().trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return fallback;
}

String? _optionalStringValue(Map<String, dynamic> json, List<String> keys) {
  final value = _stringValue(json, keys);
  return value.isEmpty ? null : value;
}

int _intValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value != null) {
      final parsed = int.tryParse(value.toString());
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return 0;
}

double _doubleValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value != null) {
      final parsed = double.tryParse(value.toString());
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return 0;
}

List<String> _listValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
  }
  return const [];
}

bool? _boolValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) {
      return value;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') {
        return true;
      }
      if (normalized == 'false') {
        return false;
      }
    }
  }
  return null;
}

DateTime? _parseDate(dynamic value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
