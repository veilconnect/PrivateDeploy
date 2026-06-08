import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_backup.dart';

void main() {
  group('cloud backup helpers', () {
    test('encodes and parses vultr backup payloads', () {
      final raw = createCloudBackupJson(
        provider: vultrCloudBackupProvider,
        apiKey: 'test-key',
        exportedAt: DateTime.utc(2026, 3, 26, 12),
        nodeRecords: {
          'node-1': {
            'label': 'fra-node',
            'region': 'fra',
          },
        },
      );

      final parsed = parseCloudBackupJson(
        raw,
        expectedProvider: vultrCloudBackupProvider,
      );

      expect(parsed.version, cloudBackupVersion);
      expect(parsed.provider, vultrCloudBackupProvider);
      expect(parsed.apiKey, 'test-key');
      expect(parsed.nodeRecords['node-1'], isA<Map<String, dynamic>>());

      final preview = inspectCloudBackupJson(
        raw,
        expectedProvider: vultrCloudBackupProvider,
      );
      expect(preview.nodeCount, 1);
      expect(preview.includesApiKey, isTrue);
      expect(preview.nodeLabels, ['fra-node']);
    });

    test('preserves provider-specific extra config in backup payloads', () {
      final raw = createCloudBackupJson(
        provider: 'ssh',
        apiKey: null,
        extra: const {
          'host': '203.0.113.10',
          'port': '22',
          'username': 'root',
        },
        exportedAt: DateTime.utc(2026, 3, 26, 12),
        nodeRecords: const {},
      );

      final parsed = parseCloudBackupJson(raw, expectedProvider: 'ssh');

      expect(parsed.provider, 'ssh');
      expect(parsed.apiKey, isNull);
      expect(parsed.extra, isNotNull);
      expect(parsed.extra!['host'], '203.0.113.10');
      expect(parsed.extra!['port'], '22');
      expect(parsed.extra!['username'], 'root');
    });

    test('rejects backup payloads from another provider', () {
      final raw = createCloudBackupJson(
        provider: 'digitalocean',
        nodeRecords: const {},
      );

      expect(
        () => parseCloudBackupJson(
          raw,
          expectedProvider: vultrCloudBackupProvider,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsupported backup version and malformed node records', () {
      expect(
        () => parseCloudBackupJson(
          '{"version":99,"provider":"vultr","nodeRecords":{}}',
          expectedProvider: vultrCloudBackupProvider,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('not supported'),
          ),
        ),
      );

      expect(
        () => inspectCloudBackupJson(
          '{"provider":"vultr","nodeRecords":{"node-1":[]}}',
          expectedProvider: vultrCloudBackupProvider,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
