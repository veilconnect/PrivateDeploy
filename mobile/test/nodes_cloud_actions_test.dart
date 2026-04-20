import 'package:flutter/material.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_throughput_probe.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_cloud_actions.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nodes cloud actions', () {
    testWidgets('confirmDeleteCloudNode deletes linked node and local profile',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(deleteResult: true);
      final linkedProfile = _profile(id: 'cloud-fra', name: 'Cloud: fra-node');
      final profileProvider = _FakeProfileProvider(
        activeProfile: linkedProfile,
        profileByName: linkedProfile,
        deleteByNameResult: true,
      );
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.connected,
        disconnectResult: true,
      );

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => confirmDeleteCloudNode(
          context: context,
          cloudProvider: cloudProvider,
          profileProvider: profileProvider,
          vpnProvider: vpnProvider,
          instance: _instance(label: 'fra-node'),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(cloudProvider.deletedInstanceId, 'fra-node');
      expect(vpnProvider.disconnectCalls, 1);
      expect(profileProvider.deletedProfileName, 'Cloud: fra-node');
      expect(find.text('Node deleted'), findsOneWidget);
    });

    testWidgets('confirmDeleteCloudNode shows failure when delete fails',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        deleteResult: false,
        error: 'Delete failed upstream',
      );
      final profileProvider = _FakeProfileProvider();
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.disconnected);

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => confirmDeleteCloudNode(
          context: context,
          cloudProvider: cloudProvider,
          profileProvider: profileProvider,
          vpnProvider: vpnProvider,
          instance: _instance(label: 'fra-node'),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(cloudProvider.deletedInstanceId, 'fra-node');
      expect(vpnProvider.disconnectCalls, 0);
      expect(profileProvider.deletedProfileName, isNull);
      expect(find.text('Delete failed upstream'), findsOneWidget);
    });

    testWidgets(
        'confirmDeleteCloudNode warns when local cleanup still needs attention',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(deleteResult: true);
      final linkedProfile = _profile(id: 'cloud-fra', name: 'Cloud: fra-node');
      final profileProvider = _FakeProfileProvider(
        activeProfile: linkedProfile,
        profileByName: linkedProfile,
        deleteByNameResult: false,
      );
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.connected,
        disconnectResult: false,
      );

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => confirmDeleteCloudNode(
          context: context,
          cloudProvider: cloudProvider,
          profileProvider: profileProvider,
          vpnProvider: vpnProvider,
          instance: _instance(label: 'fra-node'),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(cloudProvider.deletedInstanceId, 'fra-node');
      expect(vpnProvider.disconnectCalls, 1);
      expect(profileProvider.deletedProfileName, 'Cloud: fra-node');
      expect(
        find.text('Node deleted, but local cleanup needs attention'),
        findsOneWidget,
      );
    });

    testWidgets('showCloudApiKeyFlow saves key and refreshes callback',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        apiKey: 'old-key',
        setApiKeyResult: true,
      );
      var onSavedCalls = 0;

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCloudApiKeyFlow(
          context: context,
          cloudProvider: cloudProvider,
          onSaved: () async => onSavedCalls += 1,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  new-key  ');
      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.savedApiKey, 'new-key');
      expect(onSavedCalls, 1);
      expect(find.text('API key saved and verified'), findsOneWidget);
    });

    testWidgets('showCloudApiKeyFlow keeps dialog open on save failure',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        setApiKeyResult: false,
        error: 'Invalid API key',
      );
      var onSavedCalls = 0;

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCloudApiKeyFlow(
          context: context,
          cloudProvider: cloudProvider,
          onSaved: () async => onSavedCalls += 1,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bad-key');
      await tester.tap(find.text('Verify & Save'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(cloudProvider.savedApiKey, 'bad-key');
      expect(onSavedCalls, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Invalid API key'), findsOneWidget);
      expect(find.text('API key saved and verified'), findsNothing);
    });

    testWidgets(
        'showCreateCloudNodeFlow opens dialog immediately while loading',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        isLoadingRegions: true,
        isLoadingPlans: true,
      );

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCreateCloudNodeFlow(
          context: context,
          cloudProvider: cloudProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();
      expect(find.text('Deploy Node'), findsOneWidget);
      expect(find.text('Loading regions and plans...'), findsOneWidget);
      expect(cloudProvider.loadRegionsCalls, 0);
      expect(cloudProvider.loadPlansCalls, 0);
    });

    testWidgets('showCreateCloudNodeFlow retries loading missing options',
        (tester) async {
      final cloudProvider = _FakeCloudProvider();

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCreateCloudNodeFlow(
          context: context,
          cloudProvider: cloudProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Deploy Node'), findsOneWidget);
      expect(
        find.text('Deployment options are unavailable right now.'),
        findsOneWidget,
      );
      final initialRegionLoads = cloudProvider.loadRegionsCalls;
      final initialPlanLoads = cloudProvider.loadPlansCalls;
      expect(initialRegionLoads, greaterThanOrEqualTo(1));
      expect(initialPlanLoads, greaterThanOrEqualTo(1));

      await tester.tap(find.text('Retry Loading'));
      await tester.pump();

      expect(cloudProvider.loadRegionsCalls, initialRegionLoads + 1);
      expect(cloudProvider.loadPlansCalls, initialPlanLoads + 1);
    });

    testWidgets('showCreateCloudNodeFlow deploys selected cloud node',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        regions: [
          CloudRegion(
            id: 'nrt',
            city: 'Tokyo',
            country: 'Japan',
            continent: 'Asia',
          ),
        ],
        plans: [
          CloudPlan(
            id: 'vc2-1c-1gb',
            ram: 1024,
            vcpuCount: 1,
            disk: 25,
            monthlyCost: 6.0,
            locations: const ['nrt'],
          ),
        ],
        createInstanceResult: true,
      );

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCreateCloudNodeFlow(
          context: context,
          cloudProvider: cloudProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '  tokyo-edge  ');
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tokyo, Japan').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1vCPU').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();

      expect(cloudProvider.createdRegion, 'nrt');
      expect(cloudProvider.createdPlan, 'vc2-1c-1gb');
      expect(cloudProvider.createdLabel, 'tokyo-edge');
      expect(
          find.text('Node deploying... It takes 3-5 minutes.'), findsOneWidget);
    });

    testWidgets('showCreateCloudNodeFlow shows create failure message',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        regions: [
          CloudRegion(
            id: 'nrt',
            city: 'Tokyo',
            country: 'Japan',
            continent: 'Asia',
          ),
        ],
        plans: [
          CloudPlan(
            id: 'vc2-1c-1gb',
            ram: 1024,
            vcpuCount: 1,
            disk: 25,
            monthlyCost: 6.0,
            locations: const ['nrt'],
          ),
        ],
        createInstanceResult: false,
        error: 'Failed to create instance',
      );

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => showCreateCloudNodeFlow(
          context: context,
          cloudProvider: cloudProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'tokyo-edge');
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tokyo, Japan').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1vCPU').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();

      expect(cloudProvider.createdRegion, 'nrt');
      expect(cloudProvider.createdPlan, 'vc2-1c-1gb');
      expect(cloudProvider.createdLabel, 'tokyo-edge');
      expect(find.text('Failed to create instance'), findsOneWidget);
    });

    testWidgets('testAllCloudNodesLatency shows benchmark winner details',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        instances: [_instance(label: 'fra-node')],
        benchmarkLatencyResult: CloudLatencyCheck.success(
          latencyMs: 24,
          endpointLabel: 'Trojan',
          updatedAt: DateTime.now(),
          mode: CloudProbeMode.benchmark,
          sampleCount: 3,
          successfulSamples: 3,
        ),
      );
      final profileProvider = _FakeProfileProvider();
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.disconnected);

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => testAllCloudNodesLatency(
          context: context,
          cloudProvider: cloudProvider,
          profileProvider: profileProvider,
          vpnProvider: vpnProvider,
          throughputProbe: () async => const CloudThroughputSample(
            bytes: 1000000,
            elapsedMs: 250,
            speedMbps: 32.0,
          ),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Best benchmark: fra-node (32.0 Mbps) via Trojan • 24 ms latency',
        ),
        findsOneWidget,
      );
      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.disconnectCalls, 1);
      expect(
          vpnProvider.lastConfigJson, isNot(contains('"type": "hysteria2"')));
      expect(vpnProvider.lastConfigJson, isNot(contains('"type": "vless"')));
    });

    testWidgets('testAllCloudNodesLatency asks before interrupting active vpn',
        (tester) async {
      final cloudProvider = _FakeCloudProvider(
        instances: [_instance(label: 'fra-node')],
      );
      final profileProvider = _FakeProfileProvider();
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.connected);

      await _pumpCloudActionHarness(
        tester,
        cloudProvider: cloudProvider,
        onRun: (context) => testAllCloudNodesLatency(
          context: context,
          cloudProvider: cloudProvider,
          profileProvider: profileProvider,
          vpnProvider: vpnProvider,
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Benchmark All Nodes'), findsOneWidget);
      expect(find.text('Start Benchmark'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(vpnProvider.disconnectCalls, 0);
      expect(vpnProvider.connectCalls, 0);
      expect(cloudProvider.storedChecks, isEmpty);
    });
  });
}

Future<void> _pumpCloudActionHarness(
  WidgetTester tester, {
  required _FakeCloudProvider cloudProvider,
  required Future<void> Function(BuildContext context) onRun,
}) async {
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<CloudProvider>.value(
      value: cloudProvider,
      child: ScreenUtilInit(
        designSize: const Size(375, 812),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, _) {
          return MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return Center(
                    child: ElevatedButton(
                      onPressed: () => onRun(context),
                      child: const Text('Run'),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
}

CloudInstance _instance({
  required String label,
}) {
  return CloudInstance(
    id: label,
    provider: 'vultr',
    label: label,
    status: 'active',
    region: 'fra',
    plan: 'vc2-1c-1gb',
    ipv4: '1.2.3.4',
    createdAt: DateTime(2026, 3, 29),
    nodeInfo: const NodeInfo(
      ssPort: 443,
      ssPassword: 'ss',
      hyPort: 8443,
      hyPassword: 'hy-pass',
      hyServerName: 'www.bing.com',
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
    ),
  );
}

Profile _profile({
  required String id,
  required String name,
}) {
  return Profile(
    id: id,
    name: name,
    isActive: false,
    createdAt: DateTime(2026, 3, 29, 12, 30),
    updatedAt: DateTime(2026, 3, 29, 12, 30),
  );
}

class _FakeCloudProvider extends ChangeNotifier implements CloudProvider {
  _FakeCloudProvider({
    this.instances = const [],
    this.regions = const [],
    this.plans = const [],
    this.isLoadingRegions = false,
    this.isLoadingPlans = false,
    this.deleteResult = true,
    this.setApiKeyResult = true,
    this.createInstanceResult = true,
    this.apiKey,
    this.error,
    CloudLatencyCheck? benchmarkLatencyResult,
    CloudFastestNodeSelection? benchmarkSelection,
  })  : benchmarkLatencyResult = benchmarkLatencyResult ??
            CloudLatencyCheck.success(
              latencyMs: 24,
              endpointLabel: 'Trojan',
              updatedAt: DateTime.now(),
              mode: CloudProbeMode.benchmark,
              sampleCount: 3,
              successfulSamples: 3,
            ),
        benchmarkSelection = benchmarkSelection ??
            const CloudFastestNodeSelection(
              error: 'No ready cloud node is available for testing',
            );

  @override
  final List<CloudInstance> instances;

  @override
  List<CloudInstance> get allInstances => instances;

  @override
  final List<CloudRegion> regions;

  @override
  final List<CloudPlan> plans;

  @override
  bool isLoadingRegions;

  @override
  bool isLoadingPlans;

  final bool deleteResult;
  final bool setApiKeyResult;
  final bool createInstanceResult;
  final CloudLatencyCheck benchmarkLatencyResult;
  final CloudFastestNodeSelection benchmarkSelection;

  @override
  final String? apiKey;

  @override
  final String? error;

  @override
  String get providerDisplayName => providerId.displayName;

  String? deletedInstanceId;
  String? savedApiKey;
  String? createdRegion;
  String? createdPlan;
  String? createdLabel;
  int loadRegionsCalls = 0;
  int loadPlansCalls = 0;
  final Map<String, CloudLatencyCheck> storedChecks = {};

  @override
  Future<void> loadRegions({bool notify = true}) async {
    loadRegionsCalls += 1;
    isLoadingRegions = false;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<void> loadPlans({bool notify = true}) async {
    loadPlansCalls += 1;
    isLoadingPlans = false;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<void> loadInstances({bool notify = true}) async {
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<bool> deleteInstance(String id) async {
    deletedInstanceId = id;
    return deleteResult;
  }

  @override
  Future<bool> setApiKey(String key) async {
    savedApiKey = key;
    return setApiKeyResult;
  }

  @override
  Future<bool> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    createdRegion = region;
    createdPlan = plan;
    createdLabel = label;
    return createInstanceResult;
  }

  @override
  Future<CloudFastestNodeSelection> benchmarkConnectableInstances() async {
    return benchmarkSelection;
  }

  @override
  Future<CloudLatencyCheck> testInstanceLatency(
    CloudInstance instance, {
    CloudProbeMode mode = CloudProbeMode.quick,
  }) async {
    final result = mode == CloudProbeMode.benchmark
        ? benchmarkLatencyResult
        : CloudLatencyCheck.success(
            latencyMs: 48,
            endpointLabel: 'Trojan',
            updatedAt: DateTime.now(),
          );
    storedChecks[instance.id] = result;
    return result;
  }

  @override
  void saveLatencyCheck(String instanceId, CloudLatencyCheck check,
      {bool notify = true}) {
    storedChecks[instanceId] = check;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  CloudFastestNodeSelection cachedFastestConnectableInstance({
    Duration maxAge = CloudProvider.latencyCacheMaxAge,
  }) {
    final entry = storedChecks.entries.firstOrNull;
    if (entry == null) {
      return benchmarkSelection;
    }
    final instance =
        instances.where((candidate) => candidate.id == entry.key).firstOrNull;
    if (instance == null) {
      return benchmarkSelection;
    }
    return CloudFastestNodeSelection(
      instance: instance,
      latencyCheck: entry.value,
      testedCount: storedChecks.length,
      successCount:
          storedChecks.values.where((item) => item.latencyMs != null).length,
      usedCachedResults: true,
    );
  }

  @override
  String? generateNodeConfig(CloudInstance instance) {
    return '{"outbounds":[{"type":"direct","tag":"test"}]}';
  }

  @override
  CloudProviderId get providerId => CloudProviderId.vultr;

  bool _benchmarkAll = false;
  bool _benchmarkAbort = false;
  @override
  bool get isBenchmarkingAll => _benchmarkAll;
  @override
  bool get benchmarkAbortRequested => _benchmarkAbort;
  @override
  void markBenchmarkAllStart() {
    _benchmarkAll = true;
    _benchmarkAbort = false;
    notifyListeners();
  }
  @override
  void markBenchmarkAllEnd() {
    _benchmarkAll = false;
    _benchmarkAbort = false;
    notifyListeners();
  }
  @override
  void requestBenchmarkAllAbort() {
    if (!_benchmarkAll) return;
    _benchmarkAbort = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileProvider extends Fake implements ProfileProvider {
  _FakeProfileProvider({
    this.activeProfile,
    this.profileByName,
    this.deleteByNameResult = true,
  });

  @override
  final Profile? activeProfile;

  final Profile? profileByName;
  final bool deleteByNameResult;
  String? deletedProfileName;

  @override
  Profile? getProfileByName(String name) {
    return profileByName?.name == name ? profileByName : null;
  }

  @override
  Future<bool> deleteProfileByName(String name) async {
    deletedProfileName = name;
    return deleteByNameResult;
  }
}

class _FakeVpnProvider extends Fake implements VpnProvider {
  _FakeVpnProvider({
    required this.status,
    this.disconnectResult = true,
  });

  @override
  VpnStatus status;

  final bool disconnectResult;
  int connectCalls = 0;
  int disconnectCalls = 0;
  String? lastConfigJson;

  @override
  String? get error => null;

  @override
  bool get isConnected => status == VpnStatus.connected;

  @override
  bool get isLoading => false;

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  TrafficStats get stats => TrafficStats.zero();

  @override
  String? get diagnosticsEgressIp => null;

  @override
  String? get diagnosticsError => null;

  @override
  bool get isRefreshingDiagnostics => false;

  @override
  DateTime? get diagnosticsUpdatedAt => null;

  @override
  List<VpnRouteDecision> get recentRouteDecisions => const [];

  @override
  String? get activeProfile => null;

  @override
  Future<bool> connect({
    String? configJson,
    String? profileName,
    Duration stabilityCheckDuration = Duration.zero,
    Duration statusPollInterval = const Duration(milliseconds: 250),
  }) async {
    connectCalls += 1;
    lastConfigJson = configJson;
    status = VpnStatus.connected;
    return true;
  }

  @override
  Future<bool> disconnect() async {
    disconnectCalls += 1;
    if (disconnectResult) {
      status = VpnStatus.disconnected;
    }
    return disconnectResult;
  }

  @override
  Future<void> refreshDiagnostics() async {}
}
