import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_test_keys.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'support/nodes_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NodesScreen', () {
    testWidgets('bootstraps workspace state and renders loaded sections',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [readyCloudTestInstance(label: 'fra-node')],
        isLoading: true,
      );
      final profileProvider = TestProfileProvider(
        profiles: const [],
        loadedProfiles: [testProfile(id: 'manual-1', name: 'Manual A')],
        isLoading: true,
      );
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.disconnected,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(profileProvider.loadProfilesCalls, 1);
      expect(vpnProvider.initializeCalls, 1);
      expect(vpnProvider.loadStatusCalls, 0);
      expect(cloudProvider.refreshCalls, 1);
      expect(cloudProvider.loadInstancesCalls, 1);
      expect(profileProvider.pruneCalls, 1);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Connect'),
        ),
        findsOneWidget,
      );
      expect(find.text('Cloud Routes'), findsWidgets);
      expect(find.text('Saved Profiles'), findsOneWidget);
      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('Manual A'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.cloud_upload), findsNothing);
    });

    testWidgets('refresh uses loadStatus instead of reinitializing vpn',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [readyCloudTestInstance(label: 'sgp-node')],
      );
      final profileProvider = TestProfileProvider(
        profiles: const [],
        loadedProfiles: [testProfile(id: 'manual-1', name: 'Manual A')],
      );
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.disconnected,
        statusAfterLoadStatus: VpnStatus.disconnected,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final refreshIndicator =
          tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
      await refreshIndicator.onRefresh();
      await tester.pumpAndSettle();

      expect(profileProvider.loadProfilesCalls, 2);
      expect(vpnProvider.initializeCalls, 1);
      expect(vpnProvider.loadStatusCalls, 1);
      expect(cloudProvider.refreshCalls, 2);
      expect(cloudProvider.loadInstancesCalls, 2);
      expect(profileProvider.pruneCalls, 2);
    });

    testWidgets(
        'clears a stale WireGuard-enabled flag when launching disconnected',
        (tester) async {
      final appSettings = TestAppSettingsProvider(
        vpnRoutingSettings: VpnRoutingSettings.defaults.copyWith(
          wireGuardIntranet: const WireGuardIntranet(
            enabled: true,
            server: '10.0.0.1',
            serverPort: 51820,
            privateKey: 'priv',
            peerPublicKey: 'pub',
            localAddress: ['10.8.0.2/24'],
          ),
        ),
      );
      expect(appSettings.wireGuardIntranet.enabled, isTrue);

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        profileProvider: TestProfileProvider(),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
        appSettingsProvider: appSettings,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // A reboot kills the tunnel but not the preference. Bootstrap must make
      // the switch honest by clearing the now-meaningless enabled flag, instead
      // of leaving the switch sitting "on" over a disconnected tunnel.
      expect(appSettings.wireGuardIntranet.enabled, isFalse);
    });

    testWidgets(
        'keeps WireGuard armed when a tunnel survives the launch',
        (tester) async {
      final appSettings = TestAppSettingsProvider(
        vpnRoutingSettings: VpnRoutingSettings.defaults.copyWith(
          wireGuardIntranet: const WireGuardIntranet(
            enabled: true,
            server: '10.0.0.1',
            serverPort: 51820,
            privateKey: 'priv',
            peerPublicKey: 'pub',
            localAddress: ['10.8.0.2/24'],
          ),
        ),
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: TestCloudProvider(hasApiKey: false),
        profileProvider: TestProfileProvider(),
        vpnProvider: TestVpnProvider(status: VpnStatus.connected),
        appSettingsProvider: appSettings,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // A surviving tunnel legitimately keeps WG armed to merge on the next
      // (re)connect — the reconciliation must not stomp it.
      expect(appSettings.wireGuardIntranet.enabled, isTrue);
    });

    testWidgets('disconnects and prunes stale active cloud profiles',
        (tester) async {
      final staleProfile =
          testProfile(id: 'cloud-old', name: 'Cloud: old-node');
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [readyCloudTestInstance(label: 'fresh-node')],
      );
      final profileProvider = TestProfileProvider(
        profiles: [staleProfile],
        loadedProfiles: [staleProfile],
        activeProfile: staleProfile,
      );
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.connected,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(vpnProvider.disconnectCalls, 1);
      expect(profileProvider.pruneCalls, 1);
      expect(
        profileProvider.lastPrunedCloudProfiles,
        {'Cloud: fresh-node'},
      );
      expect(profileProvider.activeProfile, isNull);
      expect(find.text('fresh-node'), findsOneWidget);
      expect(find.text('Disconnected'), findsWidgets);
    });

    testWidgets('opens settings and returns to workspace via system back',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
      );
      final profileProvider = TestProfileProvider(
        loadedProfiles: [testProfile(id: 'manual-1', name: 'Manual A')],
      );
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.connected,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Connect'),
        ),
        findsOneWidget,
      );
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets(
        'opens cloud access flow from action sheet when cloud access is not configured',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: TestProfileProvider(),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(NodesTestKeys.workspaceFab), findsOneWidget);

      await tester.tap(find.byKey(NodesTestKeys.workspaceFab));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NodesTestKeys.configureCloudAccessFab));
      await tester.pumpAndSettle();

      expect(find.text('Cloud Access'), findsOneWidget);
    });

    testWidgets(
        'shows cloud empty state and primary actions for first-time setup',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: false,
      );
      final profileProvider = TestProfileProvider();
      final vpnProvider = TestVpnProvider(
        status: VpnStatus.disconnected,
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Cloud Routes'), findsOneWidget);
      expect(find.text('Cloud access has not been added yet'), findsOneWidget);
      expect(find.text('Saved Profiles'), findsNothing);
      expect(find.text('Vultr'), findsOneWidget);
      expect(find.text('DigitalOcean'), findsOneWidget);
      expect(find.text('SSH'), findsOneWidget);
      expect(find.byKey(NodesTestKeys.workspaceFab), findsOneWidget);
    });

    testWidgets(
        'shows saved profiles before cloud routes when local routes are the only usable path',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        instances: [
          testCloudInstance(
            label: 'warming-node',
            status: 'active',
            nodeInfo: null,
          ),
        ],
      );
      final profileProvider = TestProfileProvider(
        loadedProfiles: [testProfile(id: 'manual-1', name: 'Manual A')],
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      final savedProfilesY = tester.getTopLeft(find.text('Saved Profiles')).dy;
      final cloudRoutesY =
          tester.getTopLeft(find.text('Cloud Routes').first).dy;

      expect(savedProfilesY, lessThan(cloudRoutesY));
    });

    testWidgets(
        'reserves bottom scroll padding so the fab does not cover the last controls',
        (tester) async {
      final cloudProvider = TestCloudProvider(
        hasApiKey: true,
        instances: [readyCloudTestInstance(label: 'sgp-node')],
      );

      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        child: const NodesScreen(),
        cloudProvider: cloudProvider,
        profileProvider: TestProfileProvider(),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      final listView = tester.widget<ListView>(find.byType(ListView));
      expect(listView.padding, isA<EdgeInsets>());
      final padding = listView.padding! as EdgeInsets;
      expect(padding.bottom, greaterThan(100));
    });
  });
}
