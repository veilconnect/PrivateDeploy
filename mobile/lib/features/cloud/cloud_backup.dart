import 'dart:convert';

const String vultrCloudBackupProvider = 'vultr';
const int cloudBackupVersion = 1;

class CloudBackupPayload {
  final int version;
  final String provider;
  final String exportedAt;
  final String? apiKey;
  final Map<String, dynamic> nodeRecords;

  const CloudBackupPayload({
    required this.version,
    required this.provider,
    required this.exportedAt,
    required this.apiKey,
    required this.nodeRecords,
  });
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
  final provider = (data['provider'] ?? '').toString().trim();
  if (provider.isEmpty) {
    throw const FormatException('Backup is missing provider');
  }
  if (provider != expectedProvider) {
    throw FormatException(
      'Backup provider "$provider" does not match "$expectedProvider"',
    );
  }

  final nodeRecordsRaw = data['nodeRecords'];
  if (nodeRecordsRaw != null && nodeRecordsRaw is! Map) {
    throw const FormatException('Backup nodeRecords must be an object');
  }

  return CloudBackupPayload(
    version: (data['version'] as num?)?.toInt() ?? cloudBackupVersion,
    provider: provider,
    exportedAt: (data['exportedAt'] ?? '').toString(),
    apiKey: (data['apiKey'] ?? '').toString().trim().isEmpty
        ? null
        : (data['apiKey'] ?? '').toString().trim(),
    nodeRecords: nodeRecordsRaw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(nodeRecordsRaw as Map),
  );
}
