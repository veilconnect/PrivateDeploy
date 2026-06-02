import 'dart:convert';

const String vultrCloudBackupProvider = 'vultr';
const int cloudBackupVersion = 1;

/// Optional CDN-side snapshot that piggy-backs on the cloud backup so a
/// user moving to a new phone can restore CF token + Workers Custom
/// Domain binding + per-node deployments in one shot (the alternative is
/// re-running the deeplink flow on each new install, which means
/// re-binding example.test-style custom domains every time).
///
/// The CDN block is *additive*: every field is nullable, missing-key
/// imports stay valid for back-compat. Backups taken before this field
/// landed parse fine — they just don't restore CDN state.
class CdnBackup {
  const CdnBackup({
    this.token,
    this.accountId,
    this.accountEmail,
    this.workersSubdomain,
    this.customDomain,
    this.deployments,
  });

  /// CF API token, mirrors the encrypted blob the running app stores in
  /// secure storage. Nullable so a backup can carry deployments without
  /// the token if the user explicitly opts out (today we always include
  /// it when present — there is no UI toggle yet).
  final String? token;
  final String? accountId;
  final String? accountEmail;
  final String? workersSubdomain;

  /// Mirrors CdnCustomDomain.toJson — {zoneId, zoneName, subdomain}.
  final Map<String, dynamic>? customDomain;

  /// Per-node deployment records keyed by nodeId. Values mirror
  /// CdnDeployment.toJson so importers can decode without depending on
  /// the live CdnProvider's schema.
  final Map<String, Map<String, dynamic>>? deployments;

  bool get isEmpty =>
      (token == null || token!.isEmpty) &&
      (accountId == null || accountId!.isEmpty) &&
      (customDomain == null || customDomain!.isEmpty) &&
      (deployments == null || deployments!.isEmpty);

  bool get includesToken => token != null && token!.isNotEmpty;
  bool get hasCustomDomain => customDomain != null && customDomain!.isNotEmpty;
  int get deploymentCount => deployments?.length ?? 0;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    if (token != null && token!.isNotEmpty) out['token'] = token;
    if (accountId != null && accountId!.isNotEmpty)
      out['accountId'] = accountId;
    if (accountEmail != null && accountEmail!.isNotEmpty) {
      out['accountEmail'] = accountEmail;
    }
    if (workersSubdomain != null && workersSubdomain!.isNotEmpty) {
      out['workersSubdomain'] = workersSubdomain;
    }
    if (customDomain != null && customDomain!.isNotEmpty) {
      out['customDomain'] = customDomain;
    }
    if (deployments != null && deployments!.isNotEmpty) {
      out['deployments'] = deployments;
    }
    return out;
  }

  factory CdnBackup.fromJson(Map<String, dynamic> json) {
    Map<String, Map<String, dynamic>>? deps;
    final rawDeps = json['deployments'];
    if (rawDeps is Map) {
      deps = <String, Map<String, dynamic>>{};
      for (final entry in rawDeps.entries) {
        if (entry.value is Map) {
          deps[entry.key.toString()] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }
    Map<String, dynamic>? cd;
    final rawCd = json['customDomain'];
    if (rawCd is Map) {
      cd = Map<String, dynamic>.from(rawCd);
    }
    String? s(String key) {
      final v = json[key];
      if (v == null) return null;
      final t = v.toString().trim();
      return t.isEmpty ? null : t;
    }

    return CdnBackup(
      token: s('token'),
      accountId: s('accountId'),
      accountEmail: s('accountEmail'),
      workersSubdomain: s('workersSubdomain'),
      customDomain: cd,
      deployments: deps,
    );
  }
}

class CloudBackupPayload {
  final int version;
  final String provider;
  final String exportedAt;
  final String? apiKey;
  final Map<String, String>? extra;
  final Map<String, Map<String, dynamic>> nodeRecords;
  final CdnBackup? cdn;

  const CloudBackupPayload({
    required this.version,
    required this.provider,
    required this.exportedAt,
    required this.apiKey,
    required this.extra,
    required this.nodeRecords,
    this.cdn,
  });
}

class CloudBackupPreview {
  const CloudBackupPreview({
    required this.version,
    required this.provider,
    required this.exportedAt,
    required this.includesApiKey,
    required this.nodeCount,
    required this.nodeLabels,
    this.cdnPreview,
  });

  final int version;
  final String provider;
  final DateTime? exportedAt;
  final bool includesApiKey;
  final int nodeCount;
  final List<String> nodeLabels;
  final CdnBackupPreview? cdnPreview;

  String get exportedAtLabel => exportedAt?.toLocal().toString() ?? 'Unknown';
}

class CdnBackupPreview {
  const CdnBackupPreview({
    required this.includesToken,
    required this.deploymentCount,
    required this.customDomainHost,
  });

  final bool includesToken;
  final int deploymentCount;

  /// Pretty preview of the M1 binding, e.g.
  /// "relay-<node>.example.com" — empty when not bound.
  final String customDomainHost;
}

String createCloudBackupJson({
  required String provider,
  required Map<String, dynamic> nodeRecords,
  String? apiKey,
  Map<String, String>? extra,
  DateTime? exportedAt,
  CdnBackup? cdn,
}) {
  final body = <String, dynamic>{
    'version': cloudBackupVersion,
    'provider': provider,
    'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'apiKey': apiKey,
    'extra': extra,
    'nodeRecords': nodeRecords,
  };
  // Keep the cdn key absent when the snapshot is empty so legacy
  // round-trips stay byte-identical and older builds don't trip over
  // an unexpected empty object.
  if (cdn != null && !cdn.isEmpty) {
    body['cdn'] = cdn.toJson();
  }
  return const JsonEncoder.withIndent('  ').convert(body);
}

CloudBackupPayload parseCloudBackupJson(
  String raw, {
  required String expectedProvider,
}) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('Backup must be a JSON object');
  }

  final data = Map<String, dynamic>.from(decoded);
  final versionRaw = data['version'];
  final version = _parseBackupVersion(versionRaw);

  final providerRaw = data['provider'];
  if (providerRaw != null && providerRaw is! String) {
    throw const FormatException('Backup provider must be a string');
  }
  final provider = (providerRaw ?? '').toString().trim();
  if (provider.isEmpty) {
    throw const FormatException('Backup is missing provider');
  }
  if (provider != expectedProvider) {
    throw FormatException(
      'Backup provider "$provider" does not match "$expectedProvider"',
    );
  }

  final exportedAtRaw = data['exportedAt'];
  if (exportedAtRaw != null && exportedAtRaw is! String) {
    throw const FormatException('Backup exportedAt must be a string');
  }
  final exportedAt = (exportedAtRaw ?? '').toString().trim();
  if (exportedAt.isNotEmpty && DateTime.tryParse(exportedAt) == null) {
    throw const FormatException(
      'Backup exportedAt must be an ISO-8601 string',
    );
  }

  final apiKeyRaw = data['apiKey'];
  if (apiKeyRaw != null && apiKeyRaw is! String) {
    throw const FormatException('Backup apiKey must be a string');
  }
  final normalizedApiKey = (apiKeyRaw ?? '').toString().trim();

  final extraRaw = data['extra'];
  if (extraRaw != null && extraRaw is! Map) {
    throw const FormatException('Backup extra must be an object');
  }
  Map<String, String>? extra;
  if (extraRaw != null) {
    extra = <String, String>{};
    for (final entry in (extraRaw as Map).entries) {
      extra[entry.key.toString()] = entry.value?.toString() ?? '';
    }
  }

  final nodeRecordsRaw = data['nodeRecords'];
  if (nodeRecordsRaw != null && nodeRecordsRaw is! Map) {
    throw const FormatException('Backup nodeRecords must be an object');
  }

  final nodeRecords = <String, Map<String, dynamic>>{};
  if (nodeRecordsRaw != null) {
    for (final entry in (nodeRecordsRaw as Map).entries) {
      if (entry.value is! Map) {
        throw FormatException(
          'Backup node record "${entry.key}" is not a JSON object',
        );
      }
      nodeRecords[entry.key.toString()] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
  }

  CdnBackup? cdn;
  final cdnRaw = data['cdn'];
  if (cdnRaw != null) {
    if (cdnRaw is! Map) {
      throw const FormatException('Backup cdn must be an object');
    }
    final parsed = CdnBackup.fromJson(Map<String, dynamic>.from(cdnRaw));
    // Treat an explicitly-empty cdn object as "no CDN" so downstream
    // doesn't have to repeat the isEmpty check.
    cdn = parsed.isEmpty ? null : parsed;
  }

  return CloudBackupPayload(
    version: version,
    provider: provider,
    exportedAt: exportedAt,
    apiKey: normalizedApiKey.isEmpty ? null : normalizedApiKey,
    extra: extra,
    nodeRecords: nodeRecords,
    cdn: cdn,
  );
}

CloudBackupPreview inspectCloudBackupJson(
  String raw, {
  required String expectedProvider,
}) {
  final payload = parseCloudBackupJson(raw, expectedProvider: expectedProvider);
  final nodeLabels = payload.nodeRecords.entries.map((entry) {
    final label = (entry.value['label'] ?? entry.key).toString().trim();
    return label.isEmpty ? entry.key : label;
  }).toList()
    ..sort();

  CdnBackupPreview? cdnPreview;
  final cdn = payload.cdn;
  if (cdn != null) {
    String host = '';
    final cd = cdn.customDomain;
    if (cd != null) {
      final sub = (cd['subdomain'] ?? '').toString().trim();
      final zone = (cd['zoneName'] ?? '').toString().trim();
      if (sub.isNotEmpty && zone.isNotEmpty) {
        host = '$sub-<node>.$zone';
      }
    }
    cdnPreview = CdnBackupPreview(
      includesToken: cdn.includesToken,
      deploymentCount: cdn.deploymentCount,
      customDomainHost: host,
    );
  }

  return CloudBackupPreview(
    version: payload.version,
    provider: payload.provider,
    exportedAt: payload.exportedAt.isEmpty
        ? null
        : DateTime.tryParse(payload.exportedAt)?.toLocal(),
    includesApiKey: payload.apiKey != null && payload.apiKey!.isNotEmpty,
    nodeCount: payload.nodeRecords.length,
    nodeLabels: nodeLabels,
    cdnPreview: cdnPreview,
  );
}

int _parseBackupVersion(dynamic value) {
  if (value == null) {
    return cloudBackupVersion;
  }
  if (value is! num) {
    throw const FormatException('Backup version must be a number');
  }

  final version = value.toInt();
  if (version <= 0 || version > cloudBackupVersion) {
    throw FormatException('Backup version "$version" is not supported');
  }
  return version;
}
