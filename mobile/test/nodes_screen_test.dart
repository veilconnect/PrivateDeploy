import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen.dart';
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

      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Cloud Nodes'), findsWidgets);
      expect(find.text('Manual Profiles'), findsOneWidget);
      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('Manual A'), findsOneWidget);
      expect(find.byIcon(Icons.link), findsOneWidget);
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

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(profileProvider.loadProfilesCalls, 2);
      expect(vpnProvider.initializeCalls, 1);
      expect(vpnProvider.loadStatusCalls, 1);
      expect(cloudProvider.refreshCalls, 2);
      expect(cloudProvider.loadInstancesCalls, 2);
      expect(profileProvider.pruneCalls, 2);
    });

    testWidgets('disconnects and prunes stale active cloud profiles',
        (tester) async {
      final staleProfile = testProfile(id: 'cloud-old', name: 'Cloud: old-node');
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

      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('shows journey progress for first-time cloud setup',
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

      expect(find.text('Add cloud access'), findsOneWidget);
      expect(find.text('Add access'), findsOneWidget);
      expect(find.text('Prepare route'), findsOneWidget);
      expect(find.text('Connect'), findsWidgets);
      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Next'), findsNWidgets(2));
    });
  });
}
