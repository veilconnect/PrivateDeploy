import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CloudProvider.normalizeInstanceLabel', () {
    test('keeps non-empty labels after trimming', () {
      expect(
        CloudProvider.normalizeInstanceLabel('  fra-node-1  '),
        'fra-node-1',
      );
    });

    test('generates fallback label when left blank', () {
      final label = CloudProvider.normalizeInstanceLabel(
        '   ',
        now: DateTime.utc(2026, 3, 26, 10, 45, 12),
      );

      expect(label, 'node-260326104512');
    });
  });

  group('CloudProvider.validateDeploymentSelection', () {
    final regions = [
      CloudRegion(
        id: 'nrt',
        city: 'Tokyo',
        country: 'Japan',
        continent: 'Asia',
      ),
      CloudRegion(
        id: 'fra',
        city: 'Frankfurt',
        country: 'Germany',
        continent: 'Europe',
      ),
    ];
    final plans = [
      CloudPlan(
        id: 'vc2-1c-1gb',
        ram: 1024,
        vcpuCount: 1,
        disk: 25,
        monthlyCost: 6.0,
        locations: ['nrt'],
      ),
      CloudPlan(
        id: 'vc2-1c-2gb',
        ram: 2048,
        vcpuCount: 1,
        disk: 55,
        monthlyCost: 12.0,
        locations: ['fra'],
      ),
    ];

    test('rejects unknown regions', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'lax',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        'Selected region is unavailable',
      );
    });

    test('rejects plans that are unavailable in selected region', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'fra',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        'Selected plan is not available in the chosen region',
      );
    });

    test('accepts matching region and plan selections', () {
      expect(
        CloudProvider.validateDeploymentSelection(
          region: 'nrt',
          plan: 'vc2-1c-1gb',
          regions: regions,
          plans: plans,
        ),
        isNull,
      );
    });
  });

  group('CloudProvider.selectFastestConnectableInstance', () {
    test('selects the lowest latency node from fresh cached results', () async {
      final instances = [
        CloudInstance(
          id: 'sgp',
          provider: 'vultr',
          label: 'sgp',
          status: 'active',
          region: 'sgp',
          plan: 'vc2-1c-1gb',
          ipv4: '1.1.1.1',
          nodeInfo: const NodeInfo(
            ssPort: 443,
            ssPassword: 'ss',
            hyPort: 0,
            hyPassword: '',
            hyServerName: '',
            hyInsecure: null,
            vlessPort: 0,
            vlessUuid: '',
            vlessPublicKey: '',
            vlessShortId: '',
            vlessServerName: '',
            trojanPort: 8443,
            trojanPassword: 'trojan',
            trojanServerName: '',
            trojanInsecure: null,
          ),
        ),
        CloudInstance(
          id: 'fra',
          provider: 'vultr',
          label: 'fra',
          status: 'active',
          region: 'fra',
          plan: 'vc2-1c-1gb',
          ipv4: '2.2.2.2',
          nodeInfo: const NodeInfo(
            ssPort: 443,
            ssPassword: 'ss',
            hyPort: 0,
            hyPassword: '',
            hyServerName: '',
            hyInsecure: null,
            vlessPort: 0,
            vlessUuid: '',
            vlessPublicKey: '',
            vlessShortId: '',
            vlessServerName: '',
            trojanPort: 8443,
            trojanPassword: 'trojan',
            trojanServerName: '',
            trojanInsecure: null,
          ),
        ),
      ];

      final responses = <String, CloudLatencyCheck>{
        'sgp': CloudLatencyCheck.success(
          latencyMs: 62,
          endpointLabel: 'Shadowsocks',
          updatedAt: DateTime.now(),
        ),
        'fra': CloudLatencyCheck.success(
          latencyMs: 28,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
        ),
      };

      final provider = CloudProvider(
        latencyProbe: (instance) async => responses[instance.id]!,
      );
      provider
        ..instances.clear()
        ..instances.addAll(instances);

      await provider.testInstanceLatency(instances[0]);
      await provider.testInstanceLatency(instances[1]);

      final selection = await provider.selectFastestConnectableInstance();

      expect(selection.instance?.id, 'fra');
      expect(selection.latencyCheck?.latencyMs, 28);
      expect(selection.latencyCheck?.endpointLabel, 'Trojan');
      expect(selection.usedCachedResults, isTrue);
    });

    test('refreshes stale checks before selecting fastest node', () async {
      final instance = CloudInstance(
        id: 'nrt',
        provider: 'vultr',
        label: 'nrt',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '3.3.3.3',
        nodeInfo: const NodeInfo(
          ssPort: 443,
          ssPassword: 'ss',
          hyPort: 0,
          hyPassword: '',
          hyServerName: '',
          hyInsecure: null,
          vlessPort: 0,
          vlessUuid: '',
          vlessPublicKey: '',
          vlessShortId: '',
          vlessServerName: '',
          trojanPort: 8443,
          trojanPassword: 'trojan',
          trojanServerName: '',
          trojanInsecure: null,
        ),
      );

      var probeCalls = 0;
      final provider = CloudProvider(
        latencyProbe: (_) async {
          probeCalls += 1;
          return CloudLatencyCheck.success(
            latencyMs: 35,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
          );
        },
      );
      provider.instances.add(instance);

      final selection = await provider.selectFastestConnectableInstance();

      expect(selection.instance?.id, 'nrt');
      expect(selection.usedCachedResults, isFalse);
      expect(probeCalls, 1);
    });
  });
}
