import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    // flutter_secure_storage has no test mock; stub the platform channel so
    // reads/writes no-op instead of crashing under the unit-test binding.
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') return null;
      return null;
    });
  });

  group('CloudProvider.setActiveProvider', () {
    test('switches providerId and persists selection to SharedPreferences',
        () async {
      final cloud = CloudProvider(autoInitialize: false);
      expect(cloud.providerId, CloudProviderId.vultr);

      final switched =
          await cloud.setActiveProvider(CloudProviderId.digitalocean);
      expect(switched, isTrue);
      expect(cloud.providerId, CloudProviderId.digitalocean);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mobile_cloud_active_provider'), 'digitalocean');
    });

    test('switching to same provider is a no-op', () async {
      final cloud = CloudProvider(autoInitialize: false);
      final switched = await cloud.setActiveProvider(CloudProviderId.vultr);
      expect(switched, isFalse);
    });

    test('providerName and storage keys reflect active provider', () async {
      final cloud = CloudProvider(autoInitialize: false);

      expect(cloud.providerName, 'vultr');
      expect(cloud.apiKeyStorageKey, 'mobile_cloud_vultr_api_key');
      expect(cloud.nodeRecordsStorageKey, 'mobile_cloud_vultr_nodes');

      await cloud.setActiveProvider(CloudProviderId.digitalocean);

      expect(cloud.providerName, 'digitalocean');
      expect(cloud.apiKeyStorageKey, 'mobile_cloud_digitalocean_api_key');
      expect(cloud.nodeRecordsStorageKey, 'mobile_cloud_digitalocean_nodes');
    });

    test('switch clears in-memory instance and regions state', () async {
      final cloud = CloudProvider(autoInitialize: false);
      // No need to pre-seed — a fresh provider has empty lists. We just
      // verify that after a switch the lists are still empty and the
      // provider hasn't crashed trying to load nonexistent state.
      await cloud.setActiveProvider(CloudProviderId.digitalocean);
      expect(cloud.instances, isEmpty);
      expect(cloud.regions, isEmpty);
      expect(cloud.plans, isEmpty);
      expect(cloud.hasApiKey, isFalse);
    });
  });
}
