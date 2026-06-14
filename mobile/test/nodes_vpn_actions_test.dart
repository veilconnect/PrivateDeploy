import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_config_builder.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_vpn_actions.dart';
import 'package:privatedeploy_mobile/features/profiles/bundled_rule_set_registry.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('autoFailoverToNextCloudNode', () {
    testWidgets(
        'falls back to saved cloud profiles when cloud access is absent',
        (tester) async {
      final backup = _profile(
        id: 'backup-profile',
        name: 'Cloud: backup-node',
        content: '{"outbounds":[{"type":"direct"}]}',
      );
      final profileProvider = _FakeProfileProvider(
        profiles: [
          _profile(
            id: 'primary-profile',
            name: 'Cloud: primary-node',
            content: '{"outbounds":[{"type":"block"}]}',
          ),
          backup,
        ],
      );
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.connected);

      final switched = await autoFailoverToNextCloudNode(
        cloudProvider: _FakeCloudProvider(),
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
        triedProfileNames: {'Cloud: primary-node'},
      );

      expect(switched, true);
      expect(profileProvider.activatedProfileIds, ['backup-profile']);
      expect(vpnProvider.disconnectCalls, 1);
      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.lastProfileName, 'Cloud: backup-node');
      // Failover now normalizes the saved config with the routing settings
      // (so the WG overlay / custom rules carry over), not the raw bytes.
      expect(
        vpnProvider.lastConfigJson,
        normalizeProfileConfigForCurrentPlatform(
            '{"outbounds":[{"type":"direct"}]}'),
      );
    });

    testWidgets('failover keeps CN split-routing (bundled rule-set paths)',
        (tester) async {
      // The connect path passes BundledRuleSetRegistry.paths so the
      // normalizer can emit the pd-geosite-cn/pd-geoip-cn direct rules.
      // Failover must do the same — without it, split-mode users silently
      // lose ALL domestic routing after an auto-failover until the next
      // manual connect.
      BundledRuleSetRegistry.setPathsForTesting(const BundledRuleSetPaths(
        geositeCnPath: '/tmp/test-geosite-cn.srs',
        geoipCnPath: '/tmp/test-geoip-cn.srs',
      ));
      addTearDown(() => BundledRuleSetRegistry.setPathsForTesting(
          const BundledRuleSetPaths()));

      const splitConfig = '{"outbounds":['
          '{"type":"shadowsocks","tag":"proxy","server":"203.0.113.9",'
          '"server_port":8388,"method":"aes-256-gcm","password":"x"},'
          '{"type":"direct","tag":"direct"}],'
          '"route":{"final":"proxy"}}';
      final backup = _profile(
        id: 'backup-profile',
        name: 'Cloud: backup-node',
        content: splitConfig,
      );
      final profileProvider = _FakeProfileProvider(profiles: [backup]);
      final vpnProvider = _FakeVpnProvider(status: VpnStatus.connected);

      final switched = await autoFailoverToNextCloudNode(
        cloudProvider: _FakeCloudProvider(),
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
        triedProfileNames: {},
      );

      expect(switched, true);
      expect(vpnProvider.lastConfigJson, contains('pd-geosite-cn'),
          reason: 'CN direct rules must survive auto-failover');
      expect(
        vpnProvider.lastConfigJson,
        normalizeProfileConfigForCurrentPlatform(
          splitConfig,
          bundledRuleSetPaths: BundledRuleSetRegistry.paths,
        ),
      );
    });
  });

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

    testWidgets('hot-swaps the proxy in without bouncing a live WG tunnel',
        (tester) async {
      const config = '{"outbounds":[{"type":"direct","tag":"direct"}],'
          '"endpoints":[{"type":"wireguard","tag":"wireguard-intranet",'
          '"private_key":"x","peers":[]}]}';
      final profile = _profile(
        id: 'cloud-profile',
        name: 'Cloud: primary-node',
        content: config,
      );
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.connected,
        proxylessTunnel: true,
        intranetWireguardLive: true,
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeConfigJson: config,
            activeProfile: profile,
            profiles: [profile],
          ),
          cloudProvider: _FakeCloudProvider(),
          onUseCloudNode: (_) async {},
          successMessage: 'VPN connected successfully',
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pump();

      // The live WG tunnel is reloaded in place — never torn down — so the
      // user is no longer told to manually close WireGuard first.
      expect(vpnProvider.disconnectCalls, 0);
      expect(vpnProvider.connectCalls, 0);
      expect(vpnProvider.swapCalls, 1);
      expect(vpnProvider.lastConfigJson, config);
      expect(find.textContaining('内网 WireGuard 将保持连接'), findsOneWidget);
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
        isDegraded: true,
        errorMessage: VpnProvider.startupProbeInconclusiveMessage,
        diagnosticsError: VpnProvider.startupProbeInconclusiveMessage,
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Cloud: ${primary.label}'),
            activeConfigJson:
                '{"outbounds":[{"type":"direct","tag":"direct"}]}',
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
      expect(
        find.text(
          'VPN connected, but Android could not confirm the public IP during startup. Traffic may still be available.',
        ),
        findsOneWidget,
      );
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
        diagnosticsEgressIp: '198.51.100.31',
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => connectSelectedProfile(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Cloud: ${primary.label}'),
            activeConfigJson:
                '{"outbounds":[{"type":"direct","tag":"direct"}]}',
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

  group('handleNodesConnect', () {
    testWidgets(
        'tries a backup route immediately when the primary is upstream-blocked',
        (tester) async {
      final primary = _readyInstance(label: 'primary-node');
      final backup = _readyInstance(label: 'backup-node');
      final primaryProfile = _profile(
        id: 'primary-profile',
        name: 'Cloud: ${primary.label}',
        content: '{"outbounds":[{"type":"direct","tag":"primary"}]}',
      );
      final backupProfile = _profile(
        id: 'backup-profile',
        name: 'Cloud: ${backup.label}',
        content: '{"outbounds":[{"type":"direct","tag":"backup"}]}',
      );
      final profileProvider = _FakeProfileProvider(
        activeProfile: primaryProfile,
        profiles: [primaryProfile, backupProfile],
      );
      final cloudProvider = _FakeCloudProvider(instances: [primary, backup]);
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.disconnected,
        connectResult: true,
        disconnectResult: true,
        degradedResults: [true, false],
        errorResults: [VpnProvider.tunnelUpstreamDegradedMessage, null],
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => handleNodesConnect(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: profileProvider,
          cloudProvider: cloudProvider,
          onUseCloudNode: (instance) => useCloudNodeAndConnect(
            context: context,
            instance: instance,
            cloudProvider: cloudProvider,
            profileProvider: profileProvider,
            vpnProvider: vpnProvider,
          ),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(vpnProvider.connectCalls, 2);
      expect(vpnProvider.disconnectCalls, 1);
      expect(profileProvider.activatedProfileIds, ['backup-profile']);
      expect(profileProvider.activeProfile?.name, 'Cloud: backup-node');
      expect(vpnProvider.lastProfileName, 'Cloud: backup-node');
      expect(vpnProvider.isDegraded, false);
    });

    testWidgets('does not rotate nodes for a transient startup probe timeout',
        (tester) async {
      final primary = _readyInstance(label: 'primary-node');
      final backup = _readyInstance(label: 'backup-node');
      final primaryProfile = _profile(
        id: 'primary-profile',
        name: 'Cloud: ${primary.label}',
        content: '{"outbounds":[{"type":"direct","tag":"primary"}]}',
      );
      final profileProvider = _FakeProfileProvider(
        activeProfile: primaryProfile,
        profiles: [
          primaryProfile,
          _profile(
            id: 'backup-profile',
            name: 'Cloud: ${backup.label}',
            content: '{"outbounds":[{"type":"direct","tag":"backup"}]}',
          ),
        ],
      );
      final cloudProvider = _FakeCloudProvider(instances: [primary, backup]);
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.disconnected,
        connectResult: true,
        disconnectResult: true,
        isDegraded: true,
        errorMessage: VpnProvider.startupProbeInconclusiveMessage,
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => handleNodesConnect(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: profileProvider,
          cloudProvider: cloudProvider,
          onUseCloudNode: (instance) => useCloudNodeAndConnect(
            context: context,
            instance: instance,
            cloudProvider: cloudProvider,
            profileProvider: profileProvider,
            vpnProvider: vpnProvider,
          ),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(vpnProvider.connectCalls, 1);
      expect(vpnProvider.disconnectCalls, 0);
      expect(profileProvider.activatedProfileIds, isEmpty);
      expect(profileProvider.activeProfile?.name, 'Cloud: primary-node');
    });

    testWidgets('stops the tunnel when every candidate is upstream-blocked',
        (tester) async {
      final primary = _readyInstance(label: 'primary-node');
      final backup = _readyInstance(label: 'backup-node');
      final primaryProfile = _profile(
        id: 'primary-profile',
        name: 'Cloud: ${primary.label}',
        content: '{"outbounds":[{"type":"direct","tag":"primary"}]}',
      );
      final backupProfile = _profile(
        id: 'backup-profile',
        name: 'Cloud: ${backup.label}',
        content: '{"outbounds":[{"type":"direct","tag":"backup"}]}',
      );
      final profileProvider = _FakeProfileProvider(
        activeProfile: primaryProfile,
        profiles: [primaryProfile, backupProfile],
      );
      final cloudProvider = _FakeCloudProvider(instances: [primary, backup]);
      final vpnProvider = _FakeVpnProvider(
        status: VpnStatus.disconnected,
        connectResult: true,
        disconnectResult: true,
        degradedResults: [true, true],
        errorResults: [
          VpnProvider.tunnelUpstreamDegradedMessage,
          VpnProvider.tunnelUpstreamDegradedMessage,
        ],
      );

      await _pumpActionHarness(
        tester,
        onRun: (context) => handleNodesConnect(
          context: context,
          vpnProvider: vpnProvider,
          profileProvider: profileProvider,
          cloudProvider: cloudProvider,
          onUseCloudNode: (instance) => useCloudNodeAndConnect(
            context: context,
            instance: instance,
            cloudProvider: cloudProvider,
            profileProvider: profileProvider,
            vpnProvider: vpnProvider,
          ),
        ),
      );

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(vpnProvider.connectCalls, 2);
      expect(vpnProvider.disconnectCalls, 1);
      expect(vpnProvider.stopDegradedSessionCalls, 1);
      expect(vpnProvider.status, VpnStatus.disconnected);
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
  String? content,
}) {
  return Profile(
    id: id,
    name: name,
    content: content,
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
  final Map<String, CloudLatencyCheck> savedLatencyChecks = {};

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

  @override
  CloudLatencyCheck? latencyCheckFor(String instanceId) {
    return savedLatencyChecks[instanceId];
  }

  @override
  void saveLatencyCheck(
    String instanceId,
    CloudLatencyCheck check, {
    bool notify = true,
  }) {
    savedLatencyChecks[instanceId] = check;
  }
}

class _FakeProfileProvider extends Fake implements ProfileProvider {
  _FakeProfileProvider({
    this.activeConfigJson,
    Profile? activeProfile,
    List<Profile>? profiles,
  })  : _activeProfile = activeProfile,
        _profiles = List<Profile>.from(profiles ?? const []) {
    _activeProfile ??=
        _profiles.where((profile) => profile.isActive).firstOrNull;
  }

  @override
  List<Profile> get profiles => _profiles;

  @override
  Profile? get activeProfile => _activeProfile;

  final List<Profile> _profiles;
  Profile? _activeProfile;

  final String? activeConfigJson;
  VpnRoutingSettings? lastRoutingSettings;

  @override
  String? get error => null;

  final List<String> activatedProfileIds = [];

  @override
  String? getActiveConfigJson({
    VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
  }) {
    lastRoutingSettings = routingSettings;
    return activeConfigJson ?? _activeProfile?.content;
  }

  @override
  Future<bool> saveProfileContent(String profileId, String content) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index != -1) {
      final updated = _profiles[index].copyWith(content: content);
      _profiles[index] = updated;
      if (_activeProfile?.id == profileId) {
        _activeProfile = updated;
      }
    }
    return true;
  }

  @override
  Future<bool> activateProfile(String profileId) async {
    activatedProfileIds.add(profileId);
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index != -1) {
      final activated = _profiles[index].copyWith(isActive: true);
      for (var i = 0; i < _profiles.length; i += 1) {
        _profiles[i] = _profiles[i].copyWith(isActive: i == index);
      }
      _profiles[index] = activated;
      _activeProfile = activated;
    }
    return true;
  }

  @override
  Future<bool> createProfile({
    required String name,
    String? subscriptionUrl,
    String? content,
    bool allowReservedPrefix = false,
  }) async {
    _profiles.add(_profile(
      id: 'profile-${_profiles.length + 1}',
      name: name,
      content: content,
    ));
    return true;
  }
}

class _FakeVpnProvider extends Fake implements VpnProvider {
  _FakeVpnProvider({
    required VpnStatus status,
    this.isLoading = false,
    this.connectResult = true,
    this.disconnectResult = true,
    this.proxylessTunnel = false,
    bool intranetWireguardLive = false,
    bool isDegraded = false,
    this.errorMessage,
    List<bool>? degradedResults,
    List<String?>? errorResults,
    this.diagnosticsEgressIp,
    this.diagnosticsError,
  })  : _status = status,
        _intranetWireguardLive = intranetWireguardLive,
        _isDegraded = isDegraded,
        _errorMessage = errorMessage,
        degradedResults = degradedResults ?? const [],
        errorResults = errorResults ?? const [];

  VpnStatus _status;

  @override
  final bool isLoading;

  final bool connectResult;
  final bool disconnectResult;
  bool proxylessTunnel;
  bool _intranetWireguardLive;

  @override
  bool get isProxylessTunnel => proxylessTunnel;

  @override
  bool get intranetWireguardLive =>
      _status == VpnStatus.connected && _intranetWireguardLive;

  @override
  bool get isDegraded => _status == VpnStatus.connected && _isDegraded;

  bool _isDegraded;

  @override
  String? get error => _errorMessage;

  final String? errorMessage;
  String? _errorMessage;
  final List<bool> degradedResults;
  final List<String?> errorResults;

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
  int swapCalls = 0;
  int disconnectCalls = 0;
  int stopDegradedSessionCalls = 0;
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
    bool proxyless = false,
  }) async {
    final resultIndex = connectCalls;
    connectCalls += 1;
    lastConfigJson = configJson;
    lastProfileName = profileName;
    _status = connectResult ? VpnStatus.connected : VpnStatus.disconnected;
    _isDegraded = resultIndex < degradedResults.length
        ? degradedResults[resultIndex]
        : _isDegraded;
    _errorMessage = resultIndex < errorResults.length
        ? errorResults[resultIndex]
        : _errorMessage;
    return connectResult;
  }

  @override
  Future<bool> swapRunningConfig({
    required String configJson,
    String? profileName,
    bool proxyless = false,
    Duration stabilityCheckDuration = Duration.zero,
    Duration statusPollInterval = const Duration(milliseconds: 250),
  }) async {
    // Hot-swap leaves the tunnel connected. Tracked on its own counter so
    // tests can tell an in-place swap from a teardown+reconnect.
    final resultIndex = swapCalls;
    swapCalls += 1;
    lastConfigJson = configJson;
    lastProfileName = profileName;
    proxylessTunnel = proxyless;
    _intranetWireguardLive =
        proxyless || configJson.contains('wireguard-intranet');
    _status = connectResult ? VpnStatus.connected : VpnStatus.disconnected;
    _isDegraded = resultIndex < degradedResults.length
        ? degradedResults[resultIndex]
        : _isDegraded;
    _errorMessage = resultIndex < errorResults.length
        ? errorResults[resultIndex]
        : _errorMessage;
    return connectResult;
  }

  @override
  Future<bool> disconnect() async {
    disconnectCalls += 1;
    _status = disconnectResult ? VpnStatus.disconnected : VpnStatus.connected;
    if (_status == VpnStatus.disconnected) {
      _isDegraded = false;
      _errorMessage = null;
    }
    return disconnectResult;
  }

  @override
  Future<bool> stopDegradedSession({String? reason}) async {
    stopDegradedSessionCalls += 1;
    _status = VpnStatus.disconnected;
    _isDegraded = false;
    _errorMessage = reason;
    return true;
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
