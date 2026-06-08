import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';

void main() {
  group('CloudProviderId', () {
    test('vultr id and storage keys are backwards compatible', () {
      // Critical: existing users already have data under these exact keys.
      // Changing the strings would orphan their records.
      expect(CloudProviderId.vultr.id, 'vultr');
      expect(
          CloudProviderId.vultr.apiKeyStorageKey, 'mobile_cloud_vultr_api_key');
      expect(CloudProviderId.vultr.nodeRecordsStorageKey,
          'mobile_cloud_vultr_nodes');
    });

    test('digitalocean id and storage keys use fresh namespace', () {
      expect(CloudProviderId.digitalocean.id, 'digitalocean');
      expect(CloudProviderId.digitalocean.apiKeyStorageKey,
          'mobile_cloud_digitalocean_api_key');
      expect(CloudProviderId.digitalocean.nodeRecordsStorageKey,
          'mobile_cloud_digitalocean_nodes');
    });

    test('display names', () {
      expect(CloudProviderId.vultr.displayName, 'Vultr');
      expect(CloudProviderId.digitalocean.displayName, 'DigitalOcean');
      expect(CloudProviderId.ssh.displayName, 'SSH');
    });

    test('tryParse returns matching enum or null', () {
      expect(CloudProviderId.tryParse('vultr'), CloudProviderId.vultr);
      expect(CloudProviderId.tryParse('digitalocean'),
          CloudProviderId.digitalocean);
      expect(CloudProviderId.tryParse('ssh'), CloudProviderId.ssh);
      expect(CloudProviderId.tryParse('aws'), isNull);
      expect(CloudProviderId.tryParse(''), isNull);
      expect(CloudProviderId.tryParse(null), isNull);
    });

    test('parseOrVultr falls back to vultr for unknown/missing input', () {
      expect(CloudProviderId.parseOrVultr(null), CloudProviderId.vultr);
      expect(CloudProviderId.parseOrVultr(''), CloudProviderId.vultr);
      expect(CloudProviderId.parseOrVultr('aws'), CloudProviderId.vultr);
      expect(CloudProviderId.parseOrVultr('digitalocean'),
          CloudProviderId.digitalocean);
      expect(CloudProviderId.parseOrVultr('ssh'), CloudProviderId.ssh);
    });

    test('storage keys never collide between providers', () {
      final keys = <String>{};
      for (final provider in CloudProviderId.values) {
        expect(keys.add(provider.apiKeyStorageKey), isTrue,
            reason: 'duplicate apiKeyStorageKey for ${provider.id}');
        expect(keys.add(provider.configStorageKey), isTrue,
            reason: 'duplicate configStorageKey for ${provider.id}');
        expect(keys.add(provider.nodeRecordsStorageKey), isTrue,
            reason: 'duplicate nodeRecordsStorageKey for ${provider.id}');
      }
    });
  });
}
