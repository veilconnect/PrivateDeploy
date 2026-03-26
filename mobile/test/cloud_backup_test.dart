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
      expect(parsed.nodeRecords['node-1'], isA<Map>());
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
  });
}
