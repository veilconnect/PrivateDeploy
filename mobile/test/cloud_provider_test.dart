import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_record.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureValues = <String, String?>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return key == null ? null : secureValues[key];
        case 'write':
          if (key != null) {
            secureValues[key] = call.arguments['value'] as String?;
          }
          return null;
        case 'delete':
          if (key != null) {
            secureValues.remove(key);
          }
          return null;
        case 'deleteAll':
          secureValues.clear();
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
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

    test('builds distinguishable redeploy labels', () {
      final label = CloudProvider.redeployInstanceLabel(
        'fra-node',
        now: DateTime.utc(2026, 5, 14, 9, 30),
      );

      expect(label, 'fra-node-redeploy-05140930');
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

  group('CloudProvider preferred endpoint selection', () {
    final instance = CloudInstance(
      id: 'fra-node',
      provider: 'vultr',
      label: 'fra-node',
      status: 'active',
      region: 'fra',
      plan: 'vc2-1c-1gb',
      ipv4: '1.2.3.4',
      nodeInfo: const NodeInfo(
        ssPort: 443,
        ssPassword: 'ss',
        hyPort: 8443,
        hyPassword: 'hy',
        hyServerName: 'example.com',
        hyInsecure: false,
        vlessPort: 9443,
        vlessUuid: 'uuid',
        vlessPublicKey: 'pub',
        vlessShortId: 'short',
        vlessServerName: 'example.com',
        trojanPort: 10443,
        trojanPassword: 'trojan',
        trojanServerName: 'example.com',
        trojanInsecure: false,
      ),
    );

    test('persists and returns manual endpoint preference', () async {
      final provider = CloudProvider(autoInitialize: false);

      await provider.setPreferredEndpointLabel(instance, 'VLESS');

      expect(provider.preferredEndpointLabelFor(instance), 'VLESS');
      expect(
        provider.availableEndpointLabelsFor(instance),
        ['Shadowsocks', 'Hysteria2', 'VLESS', 'Trojan'],
      );
    });

    test('generateNodeConfig prefers manual endpoint over latency result',
        () async {
      final provider = CloudProvider(autoInitialize: false);
      provider
        ..instances.clear()
        ..instances.add(instance)
        ..saveLatencyCheck(
          instance.id,
          CloudLatencyCheck.success(
            latencyMs: 22,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
          ),
          notify: false,
        );
      await provider.setPreferredEndpointLabel(instance, 'VLESS');

      final raw = provider.generateNodeConfig(instance);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;
      final selector = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'select',
      ) as Map<String, dynamic>;

      expect(selector['default'], 'fra-node-VLESS');
    });

    test(
        'generateNodeConfig does not lock auto mode to the last latency endpoint',
        () {
      final provider = CloudProvider(autoInitialize: false);
      provider
        ..instances.clear()
        ..instances.add(instance)
        ..saveLatencyCheck(
          instance.id,
          CloudLatencyCheck.success(
            latencyMs: 22,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
          ),
          notify: false,
        );

      final raw = provider.generateNodeConfig(instance);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;
      final selector = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'select',
      ) as Map<String, dynamic>;

      expect(selector['default'], 'auto');
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
        autoInitialize: false,
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
        autoInitialize: false,
      );
      provider.instances.add(instance);

      final selection = await provider.selectFastestConnectableInstance();

      expect(selection.instance?.id, 'nrt');
      expect(selection.usedCachedResults, isFalse);
      expect(probeCalls, 1);
    });

    test('returns recent cached winner for connect reuse without probing',
        () async {
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

      var probeCalls = 0;
      final provider = CloudProvider(
        latencyProbe: (instance) async {
          probeCalls += 1;
          return CloudLatencyCheck.success(
            latencyMs: instance.id == 'sgp' ? 48 : 26,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
          );
        },
        autoInitialize: false,
      );
      provider.instances.addAll(instances);

      await provider.testInstanceLatency(instances[0]);
      await provider.testInstanceLatency(instances[1]);

      final selection = provider.cachedFastestConnectableInstance(
        maxAge: CloudProvider.connectSelectionReuseMaxAge,
      );

      expect(selection.instance?.id, 'fra');
      expect(selection.usedCachedResults, isTrue);
      expect(probeCalls, 2);
    });

    test('benchmarkConnectableInstances prefers reliable median result',
        () async {
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

      final provider = CloudProvider(
        latencyProbe: (_) async => CloudLatencyCheck.success(
          latencyMs: 99,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
        ),
        benchmarkLatencyProbe: (instance) async {
          if (instance.id == 'sgp') {
            return CloudLatencyCheck.success(
              latencyMs: 24,
              endpointLabel: 'Trojan',
              updatedAt: DateTime.now(),
              mode: CloudProbeMode.benchmark,
              sampleCount: 3,
              successfulSamples: 3,
            );
          }
          return CloudLatencyCheck.success(
            latencyMs: 18,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
            mode: CloudProbeMode.benchmark,
            sampleCount: 3,
            successfulSamples: 1,
          );
        },
        autoInitialize: false,
      );
      provider.instances.addAll(instances);

      final selection = await provider.benchmarkConnectableInstances();

      expect(selection.instance?.id, 'sgp');
      expect(selection.latencyCheck?.isBenchmark, isTrue);
      expect(selection.latencyCheck?.successfulSamples, 3);
      expect(selection.usedCachedResults, isFalse);
    });

    test('cached selection prefers higher throughput benchmark result',
        () async {
      final instances = [
        CloudInstance(
          id: 'osaka',
          provider: 'vultr',
          label: 'osaka',
          status: 'active',
          region: 'itm',
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
          id: 'lax',
          provider: 'vultr',
          label: 'lax',
          status: 'active',
          region: 'lax',
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

      final provider = CloudProvider(autoInitialize: false);
      provider.instances.addAll(instances);
      provider.saveLatencyCheck(
        'osaka',
        CloudLatencyCheck.success(
          latencyMs: 30,
          endpointLabel: 'Shadowsocks',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
          throughputMbps: 42.0,
          throughputBytes: 1000000,
          throughputElapsedMs: 190,
        ),
      );
      provider.saveLatencyCheck(
        'lax',
        CloudLatencyCheck.success(
          latencyMs: 18,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
          throughputMbps: 21.0,
          throughputBytes: 1000000,
          throughputElapsedMs: 381,
        ),
      );

      final selection = provider.cachedFastestConnectableInstance(
        maxAge: CloudProvider.connectSelectionReuseMaxAge,
      );

      expect(selection.instance?.id, 'osaka');
      expect(selection.latencyCheck?.throughputMbps, 42.0);
    });

    test('benchmark throughput wins even when latency is slightly worse',
        () async {
      final instances = [
        CloudInstance(
          id: 'osaka',
          provider: 'vultr',
          label: 'osaka',
          status: 'active',
          region: 'itm',
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
          id: 'vultr',
          provider: 'vultr',
          label: 'vultr',
          status: 'active',
          region: 'lax',
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

      final provider = CloudProvider(autoInitialize: false);
      provider.instances.addAll(instances);
      provider.saveLatencyCheck(
        'osaka',
        CloudLatencyCheck.success(
          latencyMs: 306,
          endpointLabel: 'Shadowsocks',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
          throughputMbps: 5.85,
          throughputBytes: 1000000,
          throughputElapsedMs: 1368,
        ),
      );
      provider.saveLatencyCheck(
        'vultr',
        CloudLatencyCheck.success(
          latencyMs: 231,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
          throughputMbps: 5.77,
          throughputBytes: 1000000,
          throughputElapsedMs: 1386,
        ),
      );

      final selection = provider.cachedFastestConnectableInstance(
        maxAge: CloudProvider.connectSelectionReuseMaxAge,
      );

      expect(selection.instance?.id, 'osaka');
      expect(selection.latencyCheck?.throughputMbps, 5.85);
    });

    test('quick refresh preserves existing throughput benchmark sample',
        () async {
      final instance = CloudInstance(
        id: 'osaka',
        provider: 'vultr',
        label: 'osaka',
        status: 'active',
        region: 'itm',
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
      );

      final provider = CloudProvider(
        latencyProbe: (_) async => CloudLatencyCheck.success(
          latencyMs: 18,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
        ),
        autoInitialize: false,
      );
      provider.instances.add(instance);
      provider.saveLatencyCheck(
        instance.id,
        CloudLatencyCheck.success(
          latencyMs: 28,
          endpointLabel: 'Shadowsocks',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
          throughputMbps: 40.0,
          throughputBytes: 1000000,
          throughputElapsedMs: 200,
        ),
      );

      final result = await provider.testInstanceLatency(instance);

      expect(result.throughputMbps, 40.0);
      expect(result.latencyMs, 18);
      expect(result.endpointLabel, 'Trojan');
      expect(result.isBenchmark, isTrue);
    });
  });

  group('CloudProvider stale instance reconciliation', () {
    test('finds a replaced record by matching public IP', () {
      final replacementId = CloudProvider.findReplacementRecordId(
        instanceId: 'inst-new',
        label: 'sgp-node',
        region: 'sgp',
        ipv4: '198.51.100.15',
        ipv6: '',
        knownRecords: {
          'inst-old': VultrNodeRecord(
            instanceId: 'inst-old',
            label: 'sgp-node',
            region: 'sgp',
            ipv4: '198.51.100.15',
            ssPort: 43379,
            ssPassword: 'old-secret',
          ),
        },
        liveInstanceIds: {'inst-new'},
      );

      expect(replacementId, 'inst-old');
    });

    test('prepares replacement records with cleared stale credentials', () {
      final migrated = CloudProvider.prepareReplacementRecord(
        record: VultrNodeRecord(
          instanceId: 'inst-old',
          label: 'sgp-node',
          region: 'sgp',
          plan: 'vc2-1c-1gb',
          ipv4: '198.51.100.15',
          ssPort: 43379,
          ssPassword: 'old-secret',
          vlessPort: 43381,
          vlessUuid: 'uuid-old',
          trojanPort: 43382,
          trojanPassword: 'trojan-old',
        ),
        instanceId: 'inst-new',
        label: 'sgp-node',
        region: 'sgp',
        plan: 'vc2-1c-1gb',
        ipv4: '198.51.100.15',
        ipv6: '',
        createdAt: '2026-04-03T10:00:00Z',
      );

      expect(migrated.instanceId, 'inst-new');
      expect(migrated.ssPort, 0);
      expect(migrated.ssPassword, isEmpty);
      expect(migrated.vlessPort, 0);
      expect(migrated.trojanPort, 0);
      expect(migrated.ipv4, '198.51.100.15');
    });
  });

  group('supportedCloudProbeEndpointsForCurrentPlatform', () {
    test('keeps VLESS probing on Android for cloud TCP ranking', () {
      const nodeInfo = NodeInfo(
        ssPort: 443,
        ssPassword: 'ss',
        hyPort: 8443,
        hyPassword: 'hy',
        hyServerName: 'example.com',
        hyInsecure: true,
        vlessPort: 443,
        vlessUuid: 'uuid',
        vlessPublicKey: 'public',
        vlessShortId: 'short',
        vlessServerName: 'www.microsoft.com',
        trojanPort: 8444,
        trojanPassword: 'trojan',
        trojanServerName: 'www.microsoft.com',
        trojanInsecure: true,
      );

      expect(
        supportedCloudProbeEndpointsForCurrentPlatform(
          nodeInfo: nodeInfo,
          targetPlatform: TargetPlatform.android,
        ),
        ['Trojan', 'VLESS', 'Shadowsocks'],
      );
    });

    test('keeps VLESS probing on non-Android platforms', () {
      const nodeInfo = NodeInfo(
        ssPort: 443,
        ssPassword: 'ss',
        hyPort: 8443,
        hyPassword: 'hy',
        hyServerName: 'example.com',
        hyInsecure: true,
        vlessPort: 443,
        vlessUuid: 'uuid',
        vlessPublicKey: 'public',
        vlessShortId: 'short',
        vlessServerName: 'www.microsoft.com',
        trojanPort: 8444,
        trojanPassword: 'trojan',
        trojanServerName: 'www.microsoft.com',
        trojanInsecure: true,
      );

      expect(
        supportedCloudProbeEndpointsForCurrentPlatform(
          nodeInfo: nodeInfo,
          targetPlatform: TargetPlatform.iOS,
        ),
        ['Trojan', 'VLESS', 'Shadowsocks'],
      );
    });
  });

  group('CloudProvider.importBackupJson', () {
    // Regression: importBackupJson used to call _saveApiKey without setting
    // _hasApiKey, so Workspace UI stayed on "Cloud access not configured"
    // until the next app restart even though the key was already in storage.
    test('flips hasApiKey synchronously after restoring backup', () async {
      final provider = CloudProvider(autoInitialize: false);
      expect(provider.hasApiKey, isFalse);

      const backup = '''
{
  "version": 1,
  "provider": "vultr",
  "exportedAt": "2026-04-07T00:00:00.000Z",
  "apiKey": "TESTKEYJUSTFORUNITTESTNOTAREALONE12345",
  "nodeRecords": {}
}
''';

      await provider.importBackupJson(backup);

      expect(provider.hasApiKey, isTrue,
          reason: 'Workspace must immediately reflect the restored key without '
              'waiting for an app restart.');
      expect(provider.apiKey, 'TESTKEYJUSTFORUNITTESTNOTAREALONE12345');
    });

    test('hasApiKey stays false when backup contains no key', () async {
      final provider = CloudProvider(autoInitialize: false);

      const backup = '''
{
  "version": 1,
  "provider": "vultr",
  "exportedAt": "2026-04-07T00:00:00.000Z",
  "nodeRecords": {}
}
''';

      await provider.importBackupJson(backup);

      expect(provider.hasApiKey, isFalse);
      expect(provider.apiKey, isNull);
    });

    test(
        'ignores stale imported-backup refresh after switching active provider',
        () async {
      final provider = CloudProvider(autoInitialize: false);
      final vultrReadStarted = Completer<void>();
      final releaseVultrRead = Completer<void>();
      var delayedVultrRead = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
        final key = call.arguments['key'] as String?;
        switch (call.method) {
          case 'read':
            if (key == CloudProviderId.vultr.apiKeyStorageKey &&
                !delayedVultrRead) {
              delayedVultrRead = true;
              if (!vultrReadStarted.isCompleted) {
                vultrReadStarted.complete();
              }
              await releaseVultrRead.future;
            }
            return key == null ? null : secureValues[key];
          case 'write':
            if (key != null) {
              secureValues[key] = call.arguments['value'] as String?;
            }
            return null;
          case 'delete':
            if (key != null) {
              secureValues.remove(key);
            }
            return null;
          case 'deleteAll':
            secureValues.clear();
            return null;
          default:
            return null;
        }
      });

      const backup = '''
{
  "version": 1,
  "provider": "vultr",
  "exportedAt": "2026-04-20T00:00:00.000Z",
  "apiKey": "TESTKEYJUSTFORUNITTESTNOTAREALONE12345",
  "nodeRecords": {}
}
''';

      await provider.importBackupJson(backup);
      await vultrReadStarted.future;
      await provider.setActiveProvider(CloudProviderId.digitalocean);
      releaseVultrRead.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(provider.providerId, CloudProviderId.digitalocean);
      expect(provider.error, isNull,
          reason:
              'A stale Vultr refresh must not surface a DigitalOcean API key '
              'error after the user already switched providers.');
      expect(provider.hasApiKey, isFalse);

      await provider.setActiveProvider(CloudProviderId.vultr);
      expect(provider.apiKey, 'TESTKEYJUSTFORUNITTESTNOTAREALONE12345');
      expect(provider.hasApiKey, isTrue);
    });
  });

  group('CloudProvider.probeRegionLatencies', () {
    CloudRegion region(String id) =>
        CloudRegion(id: id, city: id, country: 'X', continent: 'Asia');

    test('probes anchored regions, flags unreachable, exposes fastest',
        () async {
      final provider = CloudProvider(
        regionLatencyProbe: (regionId) async => switch (regionId) {
          'sjc' => 80,
          'nrt' => 40,
          'icn' => null, // unreachable (e.g. blocked by carrier/regional reachability)
          _ => null,
        },
        autoInitialize: false,
      );
      provider.regions.addAll([region('sjc'), region('nrt'), region('icn')]);

      await provider.probeRegionLatencies();

      expect(provider.regionLatencyFor('nrt')?.latencyMs, 40);
      expect(provider.regionLatencyFor('sjc')?.latencyMs, 80);
      expect(provider.regionLatencyFor('icn')?.error, isNotNull);
      expect(provider.regionLatencyFor('icn')?.latencyMs, isNull);
      expect(provider.isProbingRegions, isFalse);
      expect(provider.fastestReachableRegionId(), 'nrt');
    });

    test('skips regions without a known anchor IP', () async {
      var calls = 0;
      final provider = CloudProvider(
        regionLatencyProbe: (regionId) async {
          calls += 1;
          return 10;
        },
        autoInitialize: false,
      );
      provider.regions.add(region('zzz')); // not in the Vultr anchor table

      await provider.probeRegionLatencies();

      expect(calls, 0);
      expect(provider.regionLatencyFor('zzz'), isNull);
      expect(provider.fastestReachableRegionId(), isNull);
    });

    test('caches results and re-probes only when forced', () async {
      var calls = 0;
      final provider = CloudProvider(
        regionLatencyProbe: (regionId) async {
          calls += 1;
          return 50;
        },
        autoInitialize: false,
      );
      provider.regions.add(region('sjc'));

      await provider.probeRegionLatencies();
      await provider.probeRegionLatencies(); // within cache window → no re-probe
      expect(calls, 1);

      await provider.probeRegionLatencies(force: true);
      expect(calls, 2);
    });

    test('keeps the prior result visible while a forced re-probe is in flight',
        () async {
      final gate = Completer<int?>();
      var call = 0;
      final provider = CloudProvider(
        regionLatencyProbe: (regionId) async {
          call += 1;
          if (call == 1) {
            return 70; // first probe resolves immediately
          }
          return gate.future; // second probe blocks until released
        },
        autoInitialize: false,
      );
      provider.regions.add(region('sjc'));

      await provider.probeRegionLatencies();
      expect(provider.regionLatencyFor('sjc')?.latencyMs, 70);

      final reprobe = provider.probeRegionLatencies(force: true);
      // Mid-flight the prior 70ms stays visible — NOT flipped back to a spinner,
      // which would strand the (snapshot) dropdown menu spinning forever.
      expect(provider.regionLatencyFor('sjc')?.isTesting, isFalse);
      expect(provider.regionLatencyFor('sjc')?.latencyMs, 70);

      gate.complete(90);
      await reprobe;
      expect(provider.regionLatencyFor('sjc')?.latencyMs, 90);
    });
  });

  group('CloudProvider region latency persistence', () {
    CloudRegion region(String id) =>
        CloudRegion(id: id, city: id, country: 'X', continent: 'Asia');

    test('persists probe results to storage', () async {
      await StorageService.init();
      final provider = CloudProvider(
        regionLatencyProbe: (regionId) async => regionId == 'sjc' ? 77 : null,
        autoInitialize: false,
      );
      provider.regions.addAll([region('sjc'), region('icn')]);

      await provider.probeRegionLatencies();
      // _persistRegionLatencies runs unawaited — let it flush.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final raw = StorageService.getString('mobile_cloud_region_latency_v1');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map;
      expect(decoded['sjc']['ms'], 77);
      expect(decoded['icn']['err'], 1); // unreachable persisted as err
    });

    test('restores recent readings on init and drops stale ones', () async {
      await StorageService.init();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final staleMs = DateTime.now()
          .subtract(const Duration(days: 5))
          .millisecondsSinceEpoch;
      await StorageService.saveString(
        'mobile_cloud_region_latency_v1',
        jsonEncode({
          'sjc': {'ms': 88, 'ts': nowMs},
          'icn': {'err': 1, 'ts': nowMs},
          'fra': {'ms': 40, 'ts': staleMs}, // older than max age → dropped
        }),
      );

      final provider = CloudProvider(autoInitialize: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(provider.regionLatencyFor('sjc')?.latencyMs, 88);
      expect(provider.regionLatencyFor('icn')?.error, isNotNull);
      expect(provider.regionLatencyFor('fra'), isNull);
    });
  });
}
