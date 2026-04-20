import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_cloud_actions.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_config_validation.dart';
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

    test('validateSingboxConfig rejects invalid payloads', () {
      expect(validateSingboxConfig('[]'), 'Invalid config: not a JSON object');
      expect(
        validateSingboxConfig('{"outbounds": []}'),
        'Invalid config: missing or empty "outbounds" section',
      );
      expect(
        validateSingboxConfig('{not-json}'),
        'Invalid config: not valid JSON',
      );
    });

    test('validateSingboxConfig accepts config with outbounds', () {
      expect(
        validateSingboxConfig('{"outbounds":[{"type":"direct"}]}'),
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
        find.text('Tap Connect to use the fastest node.'),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsOneWidget);

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(connectTapped, isTrue);
    });

    testWidgets('shows setup shortcuts when no routes are available',
        (tester) async {
      var configureTapped = false;
      var importTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          profileProvider: TestProfileProvider(),
          cloudProvider: TestCloudProvider(hasApiKey: false),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
          onConfigureApiKey: () => configureTapped = true,
          onImportProfile: () => importTapped = true,
          onCreateCloudNode: () {},
          onRefreshRoutes: () {},
        ),
      );

      expect(find.text('Available Routes'), findsOneWidget);
      expect(find.text('Set API Key'), findsOneWidget);
      expect(find.text('Import profile'), findsOneWidget);

      await tester.tap(find.text('Set API Key'));
      await tester.pump();
      await tester.tap(find.text('Import profile'));
      await tester.pump();

      expect(configureTapped, isTrue);
      expect(importTapped, isTrue);
    });

    testWidgets('shows refresh shortcuts while waiting for cloud credentials',
        (tester) async {
      var refreshTapped = false;
      var importTapped = false;

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
          onImportProfile: () => importTapped = true,
          onCreateCloudNode: () {},
          onRefreshRoutes: () => refreshTapped = true,
        ),
      );

      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Import profile'), findsOneWidget);

      await tester.tap(find.text('Refresh'));
      await tester.pump();
      await tester.tap(find.text('Import profile'));
      await tester.pump();

      expect(refreshTapped, isTrue);
      expect(importTapped, isTrue);
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
      expect(find.textContaining('Up '), findsWidgets);
      expect(find.textContaining('Down '), findsWidgets);
      expect(find.textContaining('Speed '), findsOneWidget);
      expect(find.text('Connection Time'), findsOneWidget);
      expect(find.text('Exit IP'), findsOneWidget);
      expect(find.text('203.0.113.7'), findsOneWidget);
      expect(find.text('Latest Route Match'), findsOneWidget);
      expect(find.text('Proxy · auto'), findsOneWidget);
      expect(find.text('PROXY'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Restart VPN'), findsOneWidget);

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
      expect(find.text('Set API Key'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.tap(find.text('Set API Key'));
      await tester.pump();

      expect(retryTapped, isTrue);
      expect(configureTapped, isTrue);
    });

    testWidgets('shows API key CTA when cloud is not configured',
        (tester) async {
      var configureTapped = false;
      var importTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(hasApiKey: false),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () => configureTapped = true,
          onImportProfile: () => importTapped = true,
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

      expect(find.text('Cloud access not configured'), findsOneWidget);
      expect(find.text('Set API Key'), findsOneWidget);
      expect(find.text('Import profile'), findsOneWidget);

      await tester.tap(find.text('Set API Key'));
      await tester.pump();
      await tester.tap(find.text('Import profile'));
      await tester.pump();

      expect(configureTapped, isTrue);
      expect(importTapped, isTrue);
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
      expect(find.text('In Use'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Ready'), findsWidgets);
      expect(find.text('Speed Test'), findsOneWidget);
      expect(find.text('Trojan'), findsOneWidget);
      expect(find.textContaining('Vultr · SGP · 1.2.3.4'), findsOneWidget);

      await tester.tap(find.text('Speed Test'));
      await tester.pump();

      expect(testedNode?.label, 'fra-node');

      await tester.tap(find.text('Node Details'));
      await tester.pumpAndSettle();

      expect(detailedNode?.label, 'fra-node');
      expect(usedNode, isNull);
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

      expect(find.text('Benchmark All'), findsOneWidget);
      await tester.tap(find.text('Benchmark All'));
      await tester.pump();

      expect(testedAll, isTrue);
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

      expect(find.text('Current Route'), findsOneWidget);
      expect(find.text('Cloud: ready-node'), findsOneWidget);
      expect(find.text('Waiting for node credentials…'), findsOneWidget);
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
      var deployTapped = false;
      var importTapped = false;

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
          onImportProfile: () => importTapped = true,
          onRetryLoad: () {},
          onCreateCloudNode: () => deployTapped = true,
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
          onTestAllCloudNodesLatency: () {},
          onManageProviderChanged: (_) async {},
        ),
      );

      expect(find.text('No cloud nodes yet'), findsOneWidget);
      expect(find.text('Deploy Node'), findsWidgets);
      expect(find.text('Import profile'), findsOneWidget);

      await tester.tap(find.text('Deploy Node').first);
      await tester.pump();
      await tester.tap(find.text('Import profile'));
      await tester.pump();

      expect(deployTapped, isTrue);
      expect(importTapped, isTrue);
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
      expect(find.text('Ready'), findsOneWidget);
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
          matching: find.text('Use & Connect'),
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
