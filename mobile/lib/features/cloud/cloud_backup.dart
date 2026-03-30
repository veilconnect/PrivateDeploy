import 'dart:convert';

const String vultrCloudBackupProvider = 'vultr';
const int cloudBackupVersion = 1;

class CloudBackupPayload {
  final int version;
  final String provider;
  final String exportedAt;
  final String? apiKey;
  final Map<String, Map<String, dynamic>> nodeRecords;

  const CloudBackupPayload({
    required this.version,
    required this.provider,
    required this.exportedAt,
    required this.apiKey,
    required this.nodeRecords,
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
  });

  final int version;
  final String provider;
  final DateTime? exportedAt;
  final bool includesApiKey;
  final int nodeCount;
  final List<String> nodeLabels;

  String get exportedAtLabel => exportedAt?.toLocal().toString() ?? 'Unknown';
}

String createCloudBackupJson({
  required String provider,
  required Map<String, dynamic> nodeRecords,
  String? apiKey,
  DateTime? exportedAt,
}) {
  return const JsonEncoder.withIndent('  ').convert({
    'version': cloudBackupVersion,
    'provider': provider,
    'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'apiKey': apiKey,
    'nodeRecords': nodeRecords,
  });
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

  return CloudBackupPayload(
    version: version,
    provider: provider,
    exportedAt: exportedAt,
    apiKey: normalizedApiKey.isEmpty ? null : normalizedApiKey,
    nodeRecords: nodeRecords,
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

  return CloudBackupPreview(
    version: payload.version,
    provider: payload.provider,
    exportedAt: payload.exportedAt.isEmpty
        ? null
        : DateTime.tryParse(payload.exportedAt)?.toLocal(),
    includesApiKey: payload.apiKey != null && payload.apiKey!.isNotEmpty,
    nodeCount: payload.nodeRecords.length,
    nodeLabels: nodeLabels,
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
