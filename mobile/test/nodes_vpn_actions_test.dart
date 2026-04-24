import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_config_builder.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_vpn_actions.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('connectSelectedProfile', () {
    testWidgets('shows busy message while vpn is already processing',
        (tester) async {
      CloudInstance? usedNode;

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(
            status: VpnStatus.connecting,
            isLoading: true,
          ),
          profileProvider: _FakeProfileProvider(
            activeConfigJson: '{"outbounds":[{"type":"direct"}]}',
          ),
          cloudProvider: _FakeCloudProvider(),
          onUseCloudNode: (instance) async => usedNode = instance,
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();

      expect(find.text('VPN is busy, please wait a moment'), findsOneWidget);
      expect(usedNode, isNull);
    });

    testWidgets('uses the only ready cloud node when no local config exists',
        (tester) async {
      CloudInstance? usedNode;
      final instance = _readyInstance(label: 'fra-node');

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: _FakeProfileProvider(activeConfigJson: null),
          cloudProvider: _FakeCloudProvider(instances: [instance]),
          onUseCloudNode: (selected) async => usedNode = selected,
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();

      expect(usedNode?.label, 'fra-node');
    });

    testWidgets('opens picker when multiple cloud nodes are ready',
        (tester) async {
      CloudInstance? usedNode;

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: _FakeProfileProvider(activeConfigJson: null),
          cloudProvider: _FakeCloudProvider(
            instances: [
              _readyInstance(label: 'sgp-node'),
              _readyInstance(label: 'fra-node'),
            ],
          ),
          onUseCloudNode: (selected) async => usedNode = selected,
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a cloud node'), findsOneWidget);

      await tester.tap(find.text('fra-node').last);
      await tester.pumpAndSettle();

      expect(usedNode?.label, 'fra-node');
    });

    testWidgets('auto-selects the fastest ready cloud node on top connect',
        (tester) async {
      CloudInstance? usedNode;
      final fastestNode = _readyInstance(label: 'fra-node');

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: _FakeProfileProvider(activeConfigJson: null),
          cloudProvider: _FakeCloudProvider(
            instances: [
              _readyInstance(label: 'sgp-node'),
              fastestNode,
            ],
            fastestSelection: CloudFastestNodeSelection(
              instance: fastestNode,
              latencyCheck: CloudLatencyCheck.success(
                latencyMs: 24,
                endpointLabel: 'Trojan',
                updatedAt: DateTime.now(),
              ),
            ),
          ),
          onUseCloudNode: (selected) async => usedNode = selected,
          autoSelectFastestCloudNode: true,
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(usedNode?.label, 'fra-node');
      expect(
        find.text('Quick-testing ready nodes and selecting the fastest one...'),
        findsOneWidget,
      );
    });

    testWidgets('reuses recent cached winner before refreshing in background',
        (tester) async {
      CloudInstance? usedNode;
      final fastestNode = _readyInstance(label: 'fra-node');

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: _FakeProfileProvider(activeConfigJson: null),
          cloudProvider: _FakeCloudProvider(
            instances: [
              _readyInstance(label: 'sgp-node'),
              fastestNode,
            ],
            cachedSelection: CloudFastestNodeSelection(
              instance: fastestNode,
              latencyCheck: CloudLatencyCheck.success(
                latencyMs: 24,
                endpointLabel: 'Trojan',
                updatedAt: DateTime.now(),
              ),
            ),
          ),
          onUseCloudNode: (selected) async => usedNode = selected,
          autoSelectFastestCloudNode: true,
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(usedNode?.label, 'fra-node');
      expect(
        find.textContaining('Using recent fastest node: fra-node'),
        findsOneWidget,
      );
    });

    testWidgets('shows config validation error before connecting',
        (tester) async {
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.disconnected);

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Manual A'),
            activeConfigJson: '[]',
          ),
          cloudProvider: _FakeCloudProvider(),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();

      expect(find.text('Invalid config: not a JSON object'), findsOneWidget);
      expect(vpnProvider.connectCalls, 0);
    });

    testWidgets('disconnects first and reconnects the selected profile',
        (tester) async {
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.connected,
        connectResult: true,
        disconnectResult: true,
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Manual A'),
            activeConfigJson: '{"outbounds":[{"type":"direct"}]}',
          ),
          cloudProvider: _FakeCloudProvider(),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(vpnProvider.disconnectCalls, 1);
      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.lastProfileName, 'Manual A');
      expect(
        vpnProvider.lastConfigJson,
        '{"outbounds":[{"type":"direct"}]}',
      );
      expect(find.text('VPN connected successfully'), findsOneWidget);
    });

    testWidgets(
        'keeps cloud connection even when startup egress probe is inconclusive',
        (tester) async {
      // Wi-Fi ↔ cellular transitions frequently make the egress probe take
      // longer than its initial window. The app must not self-disconnect in
      // that case: the VPN tunnel is up and Android will stabilize upstream
      // sockets on its own.
      final primary = _readyInstance(label: 'primary-node');
      final backup = _readyInstance(label: 'backup-node');
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.disconnected,
        connectResult: true,
        disconnectResult: true,
        diagnosticsError: VpnProvider.startupProbeInconclusiveMessage,
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Cloud: ${primary.label}'),
            activeConfigJson: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
          ),
          cloudProvider: _FakeCloudProvider(
            instances: [primary, backup],
          ),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.disconnectCalls, 0);
      expect(find.text('VPN connected successfully'), findsOneWidget);
    });

    testWidgets(
        'keeps cloud connection when startup egress is confirmed quickly',
        (tester) async {
      final primary = _readyInstance(label: 'primary-node');
      final backup = _readyInstance(label: 'backup-node');
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.disconnected,
        connectResult: true,
        disconnectResult: true,
        diagnosticsEgressIp: '192.0.2.20',
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Cloud: ${primary.label}'),
            activeConfigJson: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
          ),
          cloudProvider: _FakeCloudProvider(
            instances: [primary, backup],
          ),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.disconnectCalls, 0);
      expect(find.text('VPN connected successfully'), findsOneWidget);
    });

    testWidgets('reads routing settings from app settings provider',
        (tester) async {
      final profileProvider = _FakeProfileProvider(
        activeProfile: _profile(name: 'Manual A'),
        activeConfigJson: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
      );

      await _pumpActionHarness(
        tester,
        appSettingsProvider: _FakeAppSettingsProvider(
          settings: const VpnRoutingSettings(
            mode: VpnRoutingMode.global,
            directCnDomains: false,
            directCnIpRanges: false,
          ),
        ),
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: profileProvider,
          cloudProvider: _FakeCloudProvider(),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(
        profileProvider.lastRoutingSettings?.mode,
        VpnRoutingMode.global,
      );
    });
  });
}

Future<void> _pumpActionHarness(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onRun,
  AppSettingsProvider? appSettingsProvider,
}) async {
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(375, 812),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, _) {
        return ChangeNotifierProvider<AppSettingsProvider>.value(
          value: appSettingsProvider ?? _FakeAppSettingsProvider(),
          child: MaterialApp(
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
          ),
        );
      },
    ),
  );
  await tester.pump();
}

CloudInstance _readyInstance({
  required String label,
}) {
  return CloudInstance(
    id: label,
    provider: 'vultr',
    label: label,
    status: 'active',
    region: 'sgp',
    plan: 'vc2-1c-1gb',
    ipv4: '1.2.3.4',
    createdAt: DateTime(2026, 3, 29),
    nodeInfo: _defaultNodeInfo,
  );
}

const NodeInfo _defaultNodeInfo = NodeInfo(
  ssPort: 443,
  ssPassword: 'secret',
  hyPort: 8443,
  hyPassword: 'hy-secret',
  hyServerName: 'example.com',
  hyInsecure: false,
  vlessPort: 443,
  vlessUuid: 'uuid',
  vlessPublicKey: 'pub',
  vlessShortId: 'short',
  vlessServerName: 'example.com',
  trojanPort: 443,
  trojanPassword: 'trojan-secret',
  trojanServerName: 'example.com',
  trojanInsecure: false,
);

Profile _profile({
  String id = 'profile-1',
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

class _FakeCloudProvider extends Fake implements CloudProvider {
  _FakeCloudProvider({
    this.instances = const [],
    CloudFastestNodeSelection? fastestSelection,
    CloudFastestNodeSelection? cachedSelection,
  })  : fastestSelection = fastestSelection ??
            const CloudFastestNodeSelection(
              error: 'Latency testing did not return a usable node',
            ),
        cachedSelection = cachedSelection ??
            const CloudFastestNodeSelection(
              error: 'Latency testing did not return a usable node',
            );

  @override
  final List<CloudInstance> instances;

  @override
  List<CloudInstance> get allInstances => instances;

  final CloudFastestNodeSelection fastestSelection;
  final CloudFastestNodeSelection cachedSelection;

  @override
  String? generateNodeConfig(CloudInstance instance) {
    return buildCloudNodeConfig(
      instance,
      targetPlatform: defaultTargetPlatform,
    );
  }

  @override
  Future<CloudFastestNodeSelection> selectFastestConnectableInstance({
    bool forceRefresh = false,
    Duration maxAge = CloudProvider.latencyCacheMaxAge,
  }) async {
    return fastestSelection;
  }

  @override
  CloudFastestNodeSelection cachedFastestConnectableInstance({
    Duration maxAge = CloudProvider.latencyCacheMaxAge,
  }) {
    return cachedSelection;
  }

  @override
  bool get isBenchmarkingAll => false;

  @override
  bool get benchmarkAbortRequested => false;

  @override
  void requestBenchmarkAllAbort() {}
}

class _FakeProfileProvider extends Fake implements ProfileProvider {
  _FakeProfileProvider({
    this.activeProfile,
    this.activeConfigJson,
  });

  @override
  List<Profile> get profiles => const [];

  @override
  final Profile? activeProfile;

  final String? activeConfigJson;
  VpnRoutingSettings? lastRoutingSettings;

  @override
  String? get error => null;

  @override
  String? getActiveConfigJson({
    VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
  }) {
    lastRoutingSettings = routingSettings;
    return activeConfigJson;
  }

  @override
  Future<bool> saveProfileContent(String profileId, String content) async {
    return true;
  }
}

class _FakeVpnProvider extends Fake implements VpnProvider {
  _FakeVpnProvider({
    required VpnStatus status,
    this.isLoading = false,
    this.connectResult = true,
    this.disconnectResult = true,
    this.diagnosticsEgressIp,
    this.diagnosticsError,
  }) : _status = status;

  VpnStatus _status;

  @override
  final bool isLoading;

  final bool connectResult;
  final bool disconnectResult;

  @override
  String? get error => null;

  @override
  final String? diagnosticsEgressIp;

  @override
  final String? diagnosticsError;

  @override
  bool get isRefreshingDiagnostics => false;

  @override
  DateTime? get diagnosticsUpdatedAt => null;

  @override
  List<VpnRouteDecision> get recentRouteDecisions => const [];

  int connectCalls = 0;
  int disconnectCalls = 0;
  String? lastConfigJson;
  String? lastProfileName;

  @override
  VpnStatus get status => _status;

  @override
  bool get isConnected => _status == VpnStatus.connected;

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  TrafficStats get stats => TrafficStats.zero();

  @override
  Future<bool> connect({
    String? configJson,
    String? profileName,
    Duration stabilityCheckDuration = Duration.zero,
    Duration statusPollInterval = const Duration(milliseconds: 250),
  }) async {
    connectCalls += 1;
    lastConfigJson = configJson;
    lastProfileName = profileName;
    _status = connectResult ? VpnStatus.connected : VpnStatus.disconnected;
    return connectResult;
  }

  @override
  Future<bool> disconnect() async {
    disconnectCalls += 1;
    _status = disconnectResult ? VpnStatus.disconnected : VpnStatus.connected;
    return disconnectResult;
  }

  @override
  Future<void> refreshDiagnostics() async {}
}

class _FakeAppSettingsProvider extends ChangeNotifier
    with Fake
    implements AppSettingsProvider {
  _FakeAppSettingsProvider({
    VpnRoutingSettings? settings,
  }) : _settings = settings ?? VpnRoutingSettings.defaults;

  VpnRoutingSettings _settings;

  @override
  VpnRoutingSettings get vpnRoutingSettings => _settings;
}
