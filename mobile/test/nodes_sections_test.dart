import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
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

    test('connectableCloudInstances returns only active nodes with ip and creds',
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
        ),
      );

      expect(find.text('Processing VPN...'), findsOneWidget);
    });

    testWidgets('shows unsupported native VPN notice when runtime is unavailable',
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
        ),
      );

      expect(find.text('Disconnected'), findsOneWidget);
      expect(
        find.text('Tap Connect to use your ready cloud node automatically.'),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsOneWidget);

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(connectTapped, isTrue);
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
          ),
          profileProvider: TestProfileProvider(
            activeProfile: testProfile(name: 'Cloud: ready-node'),
          ),
          cloudProvider: TestCloudProvider(hasApiKey: true),
          onConnect: () {},
          onDisconnect: () => disconnectTapped = true,
          onRestart: () => restartTapped = true,
        ),
      );

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Selected node: Cloud: ready-node'), findsOneWidget);
      expect(find.textContaining('Up '), findsOneWidget);
      expect(find.textContaining('Down '), findsOneWidget);
      expect(find.textContaining('Speed '), findsOneWidget);
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

      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(
            hasApiKey: true,
            error: 'boom',
          ),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onRetryLoad: () => retryTapped = true,
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
        ),
      );

      expect(find.text('Failed to load cloud nodes'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retryTapped, isTrue);
    });

    testWidgets('shows API key CTA when cloud is not configured',
        (tester) async {
      var configureTapped = false;

      await pumpNodesTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: TestCloudProvider(hasApiKey: false),
          profileProvider: TestProfileProvider(),
          vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () => configureTapped = true,
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
          onTestCloudNodeLatency: (_) {},
        ),
      );

      expect(find.text('Cloud access not configured'), findsOneWidget);
      expect(find.text('Set API Key'), findsOneWidget);

      await tester.tap(find.text('Set API Key'));
      await tester.pump();

      expect(configureTapped, isTrue);
    });

    testWidgets('shows ready cloud node and forwards callbacks', (tester) async {
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
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (instance) => detailedNode = instance,
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (instance) => usedNode = instance,
          onTestCloudNodeLatency: (instance) => testedNode = instance,
        ),
      );

      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('Active Node'), findsOneWidget);
      expect(find.text('IN USE'), findsOneWidget);
      expect(find.text('38 ms'), findsOneWidget);
      expect(find.text('Fastest endpoint: Trojan'), findsOneWidget);

      await tester.tap(find.text('38 ms'));
      await tester.pump();

      expect(testedNode?.label, 'fra-node');

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Node Details'));
      await tester.pumpAndSettle();

      expect(detailedNode?.label, 'fra-node');
      expect(usedNode, isNull);
    });
  });

  group('NodesManualProfilesSection', () {
    testWidgets('renders profiles and routes popup actions', (tester) async {
      Profile? activated;

      await pumpNodesTestApp(
        tester,
        settle: true,
        child: NodesManualProfilesSection(
          profiles: [
            testProfile(id: '1', name: 'Manual A'),
            testProfile(id: '2', name: 'Manual B'),
          ],
          activeProfileId: '2',
          onActivate: (profile) => activated = profile,
          onView: (_) {},
          onEdit: (_) {},
          onDelete: (_) {},
        ),
      );

      expect(find.text('Manual Profiles'), findsOneWidget);
      expect(find.text('Manual A'), findsOneWidget);
      expect(find.text('Manual B'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use & Connect'));
      await tester.pumpAndSettle();

      expect(activated?.name, 'Manual A');
    });
  });
}
