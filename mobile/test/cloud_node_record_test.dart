import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_record.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';

void main() {
  group('VultrNodeRecord.fromJson', () {
    test('legacy JSON without provider field deserializes as vultr', () {
      // Backwards compat: users on the previous release have records
      // stored without a "provider" field. Those must load as vultr.
      final record = VultrNodeRecord.fromJson('inst-1', {
        'label': 'legacy-node',
        'region': 'lax',
        'ssPort': 23650,
        'ssPassword': 'pw',
      });

      expect(record.provider, CloudProviderId.vultr);
      expect(record.instanceId, 'inst-1');
      expect(record.label, 'legacy-node');
      expect(record.region, 'lax');
    });

    test('explicit provider field is honored', () {
      final vultrRecord = VultrNodeRecord.fromJson('a', {'provider': 'vultr'});
      final doRecord =
          VultrNodeRecord.fromJson('b', {'provider': 'digitalocean'});

      expect(vultrRecord.provider, CloudProviderId.vultr);
      expect(doRecord.provider, CloudProviderId.digitalocean);
    });

    test('unknown provider string falls back to vultr', () {
      final record =
          VultrNodeRecord.fromJson('c', {'provider': 'not-a-provider'});

      expect(record.provider, CloudProviderId.vultr);
    });
  });

  group('VultrNodeRecord.toJson', () {
    test('roundtrip preserves provider for DO record', () {
      final original = VultrNodeRecord(
        instanceId: 'd1',
        provider: CloudProviderId.digitalocean,
        label: 'do-node',
        region: 'sfo3',
        ssPort: 23650,
        ssPassword: 'pw',
      );

      final restored = VultrNodeRecord.fromJson(original.instanceId, original.toJson());

      expect(restored.provider, CloudProviderId.digitalocean);
      expect(restored.label, 'do-node');
      expect(restored.region, 'sfo3');
    });

    test('default constructor produces vultr record', () {
      final record = VultrNodeRecord(instanceId: 'v1');
      expect(record.provider, CloudProviderId.vultr);
      expect(record.toJson()['provider'], 'vultr');
    });

    test('toMergeableJson reflects provider id', () {
      final doRecord = VultrNodeRecord(
        instanceId: 'd2',
        provider: CloudProviderId.digitalocean,
      );
      expect(doRecord.toMergeableJson()['provider'], 'digitalocean');
    });

    test('toCloudInstance reflects provider id', () {
      final doRecord = VultrNodeRecord(
        instanceId: 'd3',
        provider: CloudProviderId.digitalocean,
        ssPort: 1,
        ssPassword: 'x',
      );
      expect(doRecord.toCloudInstance().provider, 'digitalocean');
    });
  });

  group('VultrNodeRecord.copyWithJson', () {
    test('preserves provider across field updates', () {
      final original = VultrNodeRecord(
        instanceId: 'd4',
        provider: CloudProviderId.digitalocean,
        region: 'sfo3',
      );
      final updated = original.copyWithJson({'region': 'nyc3'});

      expect(updated.provider, CloudProviderId.digitalocean);
      expect(updated.region, 'nyc3');
    });
  });
}
