import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_cloud_actions.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_config_validation.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations_en.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_sections.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'support/nodes_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nodes helper actions', () {
    test('isCloudManagedProfile matches cloud profile prefix', () {
      final cloudProfile = Profile(
        id: '1',
        name: 'Cloud: tokyo',
        isActive: false,
        createdAt: DateTime(2026, 3, 29),
        updatedAt: DateTime(2026, 3, 29),
      );
      final localProfile = cloudProfile.copyWith(name: 'Manual: tokyo');

      expect(isCloudManagedProfile(cloudProfile), isTrue);
      expect(isCloudManagedProfile(localProfile), isFalse);
    });

    test('cloudProfileName derives the linked local profile name', () {
      expect(
        cloudProfileName(readyCloudTestInstance(label: 'sgp-1')),
        'Cloud: sgp-1',
      );
    });

    test(
        'connectableCloudInstances returns only active nodes with ip and creds',
        () {
      final provider = TestCloudProvider(
        hasApiKey: true,
        instances: [
          readyCloudTestInstance(label: 'ready-1'),
          readyCloudTestInstance(label: 'ready-2'),
          testCloudInstance(label: 'pending', status: 'installing'),
          testCloudInstance(label: 'missing-ip', ipv4: null),
          testCloudInstance(label: 'missing-creds', nodeInfo: null),
        ],
      );

      final result = connectableCloudInstances(provider);

      expect(result.map((instance) => instance.label), ['ready-1', 'ready-2']);
    });

    test('availableCloudRouteCount includes saved cloud profiles and dedupes',
        () {
      final savedReadyProfile = testProfile(
        name: 'Cloud: ready-1',
        content: '{"outbounds":[{"type":"direct"}]}',
      );
      final savedOnlyProfile = testProfile(
        name: 'Cloud: cached-only',
        content: '{"outbounds":[{"type":"direct"}]}',
      );
      final emptyCloudProfile = testProfile(name: 'Cloud: empty');

      final count = availableCloudRouteCount(
        readyCloudNodes: [readyCloudTestInstance(label: 'ready-1')],
        profiles: [
          savedReadyProfile,
          savedOnlyProfile,
          emptyCloudProfile,
          testProfile(name: 'Manual A'),
        ],
      );

      expect(count, 2);
    });

    test('validateSingboxConfig rejects invalid payloads', () {
      final AppLocalizationsEn l10n = AppLocalizationsEn();
      expect(
        validateSingboxConfig('[]', l10n),
        'Invalid config: not a JSON object',
      );
      expect(
        validateSingboxConfig('{"outbounds": []}', l10n),
        'Invalid config: missing or empty "outbounds" section',
      );
      expect(
        validateSingboxConfig('{not-json}', l10n),
        'Invalid config: not valid JSON',
      );
    });

    test('validateSingboxConfig accepts config with outbounds', () {
      expect(
        validateSingboxConfig(
          '{"outbounds":[{"type":"direct"}]}',
          AppLocalizationsEn(),
        ),
        isNull,
      );
    });
  });

  group('NodesVpnSection', () {
    testWidgets('shows loading indicator while VPN action is in progress',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(
            status: VpnStatus.connecting,
            isLoading: true,
          ),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(hasApiKey: true),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Processing VPN...'), findsOneWidget);
    });

    testWidgets(
        'shows unsupported native VPN notice when runtime is unavailable',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(
            status: VpnStatus.disconnected,
            isSupported: false,
            unsupportedReason: 'Native core missing',
          ),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(hasApiKey: true),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Native VPN unavailable'), findsOneWidget);
      expect(find.text('Native core missing'), findsOneWidget);
    });

    testWidgets('shows connect action and ready cloud hint when disconnected',
        (tester) async {
      var connectTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'ready-node')],
          ),
          onConnect: () => connectTapped = true,
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Disconnected'), findsWidgets);
      expect(
        find.text('1 Cloud Routes · 0 Saved Profiles'),
        findsWidgets,
      );
      expect(find.text('Connect'), findsOneWidget);

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(connectTapped, isTrue);
    });

    testWidgets('counts saved cloud profile when cloud node cache is empty',
        (tester) async {
      final activeCloudProfile = testProfile(
        name: 'Cloud: vultr',
        content: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
      );

      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(
            profiles: [activeCloudProfile],
            activeProfile: activeCloudProfile,
          ),
          cloudProvider: TestCloudProvider(hasApiKey: false),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Cloud: vultr'), findsWidgets);
      expect(find.text('Cloud Routes · Disconnected'), findsOneWidget);
      expect(find.text('Available Routes'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('1 Cloud Routes · 0 Saved Profiles'), findsOneWidget);
    });

    testWidgets('does not double-count saved profile for ready cloud node',
        (tester) async {
      final activeCloudProfile = testProfile(
        name: 'Cloud: ready-node',
        content: '{"outbounds":[{"type":"direct","tag":"direct"}]}',
      );

      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(
            profiles: [activeCloudProfile],
            activeProfile: activeCloudProfile,
          ),
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'ready-node')],
          ),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Vultr · Disconnected'), findsOneWidget);
      expect(find.text('1 Cloud Routes · 0 Saved Profiles'), findsWidgets);
      expect(find.text('2 Cloud Routes · 0 Saved Profiles'), findsNothing);
    });

    testWidgets('keeps the disconnected card focused on connect state only',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(hasApiKey: false),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Available Routes'), findsOneWidget);
      expect(find.text('Set Cloud Access'), findsNothing);
      expect(find.text('Import profile'), findsNothing);
      expect(find.text('Vultr'), findsNothing);
      expect(find.text('DigitalOcean'), findsNothing);
    });

    testWidgets(
        'does not show inline refresh shortcuts while waiting for cloud credentials',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [
              testCloudInstance(
                label: 'warming-node',
                status: 'active',
                nodeInfo: null,
              ),
            ],
          ),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Refresh'), findsNothing);
      expect(find.text('Import profile'), findsNothing);
    });

    testWidgets('shows disconnect and restart controls when connected',
        (tester) async {
      var disconnectTapped = false;
      var restartTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(
            status: VpnStatus.connected,
            stats: TrafficStats(
              uploadBytes: 1024,
              downloadBytes: 2048,
              uploadSpeed: 128,
              downloadSpeed: 256,
              connectionTime: const Duration(minutes: 5),
            ),
            diagnosticsEgressIp: '203.0.113.7',
            recentRouteDecisions: [
              VpnRouteDecision(
                timestamp: DateTime(2026, 4, 20, 12, 0),
                type: VpnRouteDecisionType.proxy,
                outboundType: 'selector',
                outboundTag: 'auto',
                target: '104.18.33.45:443',
                domain: 'openai.com',
              ),
            ],
          ),
          profileProvider: TestProfileProvider(
            activeProfile: testProfile(name: 'Cloud: ready-node'),
          ),
          cloudProvider: TestCloudProvider(hasApiKey: true),
          onConnect: () {},
          onDisconnect: () => disconnectTapped = true,
          onRestart: () => restartTapped = true,
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Connected'), findsWidgets);
      expect(find.text('Cloud: ready-node'), findsWidgets);
      expect(find.text('Connection Time'), findsOneWidget);
      expect(find.text('Exit IP'), findsOneWidget);
      expect(find.text('203.0.113.7'), findsOneWidget);
      expect(find.text('Connection details'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Restart VPN'), findsOneWidget);

      await tester.tap(find.text('Connection details'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Up '), findsWidgets);
      expect(find.textContaining('Down '), findsWidgets);
      expect(find.textContaining('Speed '), findsWidgets);
      expect(find.text('Latest Route Match'), findsOneWidget);
      expect(find.text('Proxy · auto'), findsOneWidget);
      expect(find.text('PROXY'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pump();
      await tester.tap(find.text('Restart VPN'));
      await tester.pump();

      expect(disconnectTapped, isTrue);
      expect(restartTapped, isTrue);
    });
  });

  group('NodesCloudSection', () {
    testWidgets('shows retry state when cloud loading failed', (tester) async {
      var retryTapped = false;
      var configureTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            error: 'boom',
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () => configureTapped = true,
          onImportProfile: () {},
          onRetryLoad: () => retryTapped = true,
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('Failed to load'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
      expect(find.text('Set Cloud Access'), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retryTapped, isTrue);
      expect(configureTapped, isFalse);
    });

    testWidgets('shows API key CTA when cloud is not configured',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(hasApiKey: false),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('Cloud access has not been added yet'), findsOneWidget);
      expect(
        find.text(
          'Add cloud API access to list routes and create new ones on this device.',
        ),
        findsOneWidget,
      );
      expect(find.text('Set Cloud Access'), findsNothing);
      expect(find.text('Import profile'), findsNothing);
    });

    testWidgets('counts cached cloud profiles when cloud access is absent',
        (tester) async {
      final cachedCloudProfile = testProfile(
        name: 'Cloud: cached-node',
        content: '{"outbounds":[{"type":"direct"}]}',
      );

      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(hasApiKey: false),
          profileProvider: TestProfileProvider(
            profiles: [cachedCloudProfile],
            activeProfile: cachedCloudProfile,
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('Cloud Routes'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Cloud access has not been added yet'), findsOneWidget);
    });

    testWidgets('shows ready cloud node and forwards callbacks',
        (tester) async {
      CloudInstance? usedNode;
      CloudInstance? detailedNode;
      CloudInstance? testedNode;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'fra-node')],
            latencyChecks: {
              'fra-node': CloudLatencyCheck.success(
                latencyMs: 38,
                endpointLabel: 'Trojan',
                updatedAt: DateTime(2026, 3, 30, 21, 0),
              ),
            },
          ),
          profileProvider: TestProfileProvider(
            profiles: [testProfile(name: 'Cloud: fra-node')],
            activeProfile: testProfile(name: 'Cloud: fra-node'),
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.connected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (instance) => detailedNode = instance,
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (instance) => usedNode = instance,
          onTestCloudNodeLatency: (instance) => testedNode = instance,
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('In Use'), findsWidgets);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Ready'), findsWidgets);
      expect(find.text('Speed Test'), findsOneWidget);
      expect(find.text('Trojan'), findsOneWidget);
      expect(find.text('SGP'), findsOneWidget);
      expect(find.textContaining('Vultr · 1.2.3.4'), findsOneWidget);

      await tester.tap(find.text('Speed Test'));
      await tester.pump();

      expect(testedNode?.label, 'fra-node');

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node Details'));
      await tester.pumpAndSettle();

      expect(detailedNode?.label, 'fra-node');
      expect(usedNode, isNull);
    });

    testWidgets('shows the active profile outbound for the selected cloud node',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'fra-node')],
            latencyChecks: {
              'fra-node': CloudLatencyCheck.success(
                latencyMs: 38,
                endpointLabel: 'Trojan',
                updatedAt: DateTime(2026, 3, 30, 21, 0),
              ),
            },
          ),
          profileProvider: TestProfileProvider(
            profiles: [
              testProfile(
                name: 'Cloud: fra-node',
                content: '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "fra-node-SS", "fra-node-Trojan"],
      "default": "fra-node-SS"
    }
  ]
}
''',
              ),
            ],
            activeProfile: testProfile(
              name: 'Cloud: fra-node',
              content: '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "fra-node-SS", "fra-node-Trojan"],
      "default": "fra-node-SS"
    }
  ]
}
''',
            ),
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.connected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Shadowsocks'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Trojan'),
        ),
        findsNothing,
      );
    });

    testWidgets('lets the user save a manual protocol preference',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        instances: [readyCloudTestInstance(label: 'fra-node')],
      );

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: cloudProvider,
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Automatic'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Automatic'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('VLESS'));
      await tester.pumpAndSettle();

      expect(
          cloudProvider.preferredEndpointLabelFor(
            readyCloudTestInstance(label: 'fra-node'),
          ),
          'VLESS');
      expect(
        find.text('fra-node will use VLESS next time it connects.'),
        findsOneWidget,
      );
    });

    testWidgets('shows the pending protocol for a selected disconnected node',
        (tester) async {
      const selectedProfileConfig = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "fra-node-SS", "fra-node-VLESS"],
      "default": "fra-node-SS"
    }
  ]
}
''';

      final activeProfile = testProfile(
        name: 'Cloud: fra-node',
        content: selectedProfileConfig,
      );
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        instances: [readyCloudTestInstance(label: 'fra-node')],
        preferredEndpointLabels: const {'fra-node': 'VLESS'},
      );

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: cloudProvider,
          profileProvider: TestProfileProvider(
            profiles: [activeProfile],
            activeProfile: activeProfile,
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('VLESS'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Shadowsocks'),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'changing protocol on the active connected node reapplies the route',
        (tester) async {
      CloudInstance? usedNode;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'fra-node')],
          ),
          profileProvider: TestProfileProvider(
            profiles: [testProfile(name: 'Cloud: fra-node')],
            activeProfile: testProfile(name: 'Cloud: fra-node'),
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.connected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (instance) => usedNode = instance,
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      await tester.tap(
        find.descendant(
          of: find.byType(ActionChip),
          matching: find.text('Automatic'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hysteria2'));
      await tester.pumpAndSettle();

      expect(usedNode?.label, 'fra-node');
    });

    testWidgets('shows one-tap speed test when multiple nodes are ready',
        (tester) async {
      var testedAll = false;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [
              readyCloudTestInstance(label: 'sgp-node'),
              readyCloudTestInstance(label: 'fra-node'),
            ],
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () => testedAll = true,
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Measure All'));
      await tester.pump();

      expect(testedAll, isTrue);
    });

    testWidgets('filters cloud routes to the selected provider',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            providerId: CloudProviderId.vultr,
            instances: [
              readyCloudTestInstance(label: 'vultr-node', provider: 'vultr'),
              readyCloudTestInstance(
                label: 'do-node',
                provider: 'digitalocean',
              ),
            ],
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('vultr-node'), findsOneWidget);
      expect(find.text('do-node'), findsNothing);
    });

    testWidgets('shows overview metrics and waiting message for pending nodes',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [
              readyCloudTestInstance(label: 'ready-node'),
              testCloudInstance(
                label: 'warming-node',
                status: 'active',
                nodeInfo: null,
              ),
            ],
          ),
          profileProvider: TestProfileProvider(
            profiles: [testProfile(name: 'Cloud: ready-node')],
            activeProfile: testProfile(name: 'Cloud: ready-node'),
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('Ready'), findsWidgets);
      expect(find.text('Starting'), findsWidgets);
      expect(find.text('Node is still preparing connection details'),
          findsOneWidget);
    });

    testWidgets(
        'orders cloud nodes by current route, saved status, latency history, and readiness',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [
              readyCloudTestInstance(
                label: 'fresh-node',
                createdAt: DateTime(2026, 4, 4),
              ),
              testCloudInstance(
                label: 'pending-node',
                status: 'active',
                createdAt: DateTime(2026, 4, 5),
                nodeInfo: null,
              ),
              readyCloudTestInstance(
                label: 'bench-node',
                createdAt: DateTime(2026, 4, 1),
              ),
              readyCloudTestInstance(
                label: 'saved-node',
                createdAt: DateTime(2026, 4, 3),
              ),
              readyCloudTestInstance(
                label: 'current-node',
                createdAt: DateTime(2026, 3, 31),
              ),
            ],
            latencyChecks: {
              'bench-node': CloudLatencyCheck.success(
                latencyMs: 31,
                updatedAt: DateTime(2026, 4, 6, 8, 0),
                mode: CloudProbeMode.benchmark,
                throughputMbps: 58.5,
              ),
            },
          ),
          profileProvider: TestProfileProvider(
            profiles: [
              testProfile(name: 'Cloud: saved-node'),
              testProfile(name: 'Cloud: current-node'),
            ],
            activeProfile: testProfile(name: 'Cloud: current-node'),
          ),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      final currentY = tester.getTopLeft(find.text('current-node')).dy;
      final savedY = tester.getTopLeft(find.text('saved-node')).dy;
      final benchY = tester.getTopLeft(find.text('bench-node')).dy;
      final freshY = tester.getTopLeft(find.text('fresh-node')).dy;
      final pendingY = tester.getTopLeft(find.text('pending-node')).dy;

      expect(currentY, lessThan(savedY));
      expect(savedY, lessThan(benchY));
      expect(benchY, lessThan(freshY));
      expect(freshY, lessThan(pendingY));
    });

    testWidgets('shows import profile fallback when no cloud nodes exist',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: const [],
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('No cloud nodes yet'), findsOneWidget);
      expect(
        find.text('Create one cloud route, then connect from this device.'),
        findsOneWidget,
      );
      expect(find.text('Create Route'), findsNothing);
      expect(find.text('Import profile'), findsNothing);
    });

    testWidgets('shows Mbps label for benchmark result with throughput sample',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            instances: [readyCloudTestInstance(label: 'osaka')],
            latencyChecks: {
              'osaka': CloudLatencyCheck.success(
                latencyMs: 24,
                endpointLabel: 'Shadowsocks',
                updatedAt: DateTime(2026, 3, 31, 10, 30),
                mode: CloudProbeMode.benchmark,
                sampleCount: 3,
                successfulSamples: 3,
                throughputMbps: 32.0,
                throughputBytes: 1000000,
                throughputElapsedMs: 250,
              ),
            },
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('32.0 Mbps'), findsNWidgets(2));
      expect(
        find.text(
          'Shadowsocks • 3/3 probes • 32.0 Mbps • 24 ms latency',
        ),
        findsOneWidget,
      );
    });

    testWidgets('switches managed cloud provider from section chips',
        (tester) async {
      CloudProviderId? selectedProvider;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            providerId: CloudProviderId.vultr,
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (providerId) async {
            selectedProvider = providerId;
          },
        ),
      );

      expect(find.text('Vultr'), findsWidgets);
      expect(find.text('DigitalOcean'), findsOneWidget);

      await tester.tap(find.text('DigitalOcean').last);
      await tester.pump();

      expect(selectedProvider, CloudProviderId.digitalocean);
    });

    testWidgets(
        'keeps provider chips visible when selected provider has no access configured',
        (tester) async {
      CloudProviderId? selectedProvider;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: false,
            providerId: CloudProviderId.digitalocean,
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onImportProfile: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (providerId) async {
            selectedProvider = providerId;
          },
        ),
      );

      expect(find.text('DigitalOcean'), findsOneWidget);
      expect(find.text('Vultr'), findsOneWidget);
      expect(find.text('SSH'), findsOneWidget);

      await tester.tap(find.text('Vultr'));
      await tester.pump();

      expect(selectedProvider, CloudProviderId.vultr);
    });
  });

  group('NodesManualProfilesSection', () {
    testWidgets('renders profiles and routes popup actions', (tester) async {
      Profile? activated;
      Profile? viewed;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesManualProfilesSection(
          profiles: [
            testProfile(id: '1', name: 'Manual A'),
            testProfile(id: '2', name: 'Manual B'),
          ],
          activeProfileId: '1',
          onActivate: (profile) => activated = profile,
          onView: (profile) => viewed = profile,
          onEdit: (_) {},
          onDelete: (_) {},
          onSpeedTest: (_) {},
        ),
      );

      expect(find.text('Saved Profiles'), findsOneWidget);
      expect(find.text('Manual A'), findsOneWidget);
      expect(find.text('Manual B'), findsOneWidget);
      expect(find.text('Selected'), findsOneWidget);
      expect(find.text('Open Config'), findsWidgets);

      final manualACard = find.ancestor(
        of: find.text('Manual A'),
        matching: find.byType(Card),
      );
      final manualBCard = find.ancestor(
        of: find.text('Manual B'),
        matching: find.byType(Card),
      );

      await tester.tap(
        find.descendant(
          of: manualACard.first,
          matching: find.text('Open Config'),
        ),
      );
      await tester.pumpAndSettle();

      expect(viewed?.name, 'Manual A');

      await tester.tap(
        find.descendant(
          of: manualBCard.first,
          matching: find.text('Connect'),
        ),
      );
      await tester.pumpAndSettle();

      expect(activated?.name, 'Manual B');
    });

    testWidgets('sorts active profile first and then by recent updates',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesManualProfilesSection(
          profiles: [
            testProfile(
              id: 'older',
              name: 'Older Profile',
              createdAt: DateTime(2026, 3, 20, 9, 0),
              updatedAt: DateTime(2026, 3, 20, 9, 0),
            ),
            testProfile(
              id: 'recent',
              name: 'Recent Profile',
              createdAt: DateTime(2026, 3, 19, 9, 0),
              updatedAt: DateTime(2026, 4, 4, 8, 30),
            ),
            testProfile(
              id: 'active',
              name: 'Active Profile',
              createdAt: DateTime(2026, 3, 18, 9, 0),
              updatedAt: DateTime(2026, 3, 21, 9, 0),
            ),
          ],
          activeProfileId: 'active',
          onActivate: (_) {},
          onView: (_) {},
          onEdit: (_) {},
          onDelete: (_) {},
          onSpeedTest: (_) {},
        ),
      );

      final activeY = tester.getTopLeft(find.text('Active Profile')).dy;
      final recentY = tester.getTopLeft(find.text('Recent Profile')).dy;
      final olderY = tester.getTopLeft(find.text('Older Profile')).dy;

      expect(activeY, lessThan(recentY));
      expect(recentY, lessThan(olderY));
      expect(find.textContaining('Last updated: 2026-04-04 08:30'),
          findsOneWidget);
    });
  });
}
