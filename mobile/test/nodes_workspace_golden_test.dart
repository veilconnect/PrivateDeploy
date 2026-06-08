import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

import 'support/nodes_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadGoldenFonts();
  });

  group('NodesScreen goldens', () {
    testWidgets('captures onboarding workspace state', (tester) async {
      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        settle: true,
        surfaceSize: const Size(430, 1500),
        child: const NodesScreen(),
        cloudProvider: TestCloudProvider(
          hasApiKey: false,
          hasApiKeyAfterRefresh: false,
        ),
        profileProvider: TestProfileProvider(),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
      );

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/nodes_workspace_onboarding.png'),
      );
    });

    testWidgets('captures mixed route management state', (tester) async {
      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        settle: true,
        surfaceSize: const Size(430, 2000),
        child: const NodesScreen(),
        cloudProvider: TestCloudProvider(
          hasApiKey: true,
          hasApiKeyAfterRefresh: true,
          instances: [
            readyCloudTestInstance(
              label: 'current-node',
              region: 'fra',
              ipv4: '203.0.113.7',
              createdAt: DateTime(2026, 4, 5, 9, 0),
            ),
            readyCloudTestInstance(
              label: 'saved-node',
              region: 'lhr',
              ipv4: '198.51.100.21',
              createdAt: DateTime(2026, 4, 4, 12, 0),
            ),
            readyCloudTestInstance(
              label: 'bench-node',
              region: 'sin',
              ipv4: '198.51.100.33',
              createdAt: DateTime(2026, 4, 3, 8, 0),
            ),
            testCloudInstance(
              label: 'pending-node',
              region: 'syd',
              ipv4: '198.51.100.77',
              createdAt: DateTime(2026, 4, 6, 8, 30),
              status: 'active',
              nodeInfo: null,
            ),
          ],
          latencyChecks: {
            'bench-node': CloudLatencyCheck.success(
              latencyMs: 24,
              endpointLabel: 'Trojan',
              updatedAt: DateTime(2026, 4, 6, 10, 0),
              mode: CloudProbeMode.benchmark,
              sampleCount: 3,
              successfulSamples: 3,
              throughputMbps: 42.7,
            ),
          },
        ),
        profileProvider: TestProfileProvider(
          profiles: [
            testProfile(
              id: 'cloud-current',
              name: 'Cloud: current-node',
              updatedAt: DateTime(2026, 4, 5, 9, 5),
            ),
            testProfile(
              id: 'cloud-saved',
              name: 'Cloud: saved-node',
              updatedAt: DateTime(2026, 4, 4, 12, 5),
            ),
            testProfile(
              id: 'manual-a',
              name: 'Manual Tokyo',
              updatedAt: DateTime(2026, 4, 6, 11, 30),
            ),
          ],
          loadedProfiles: [
            testProfile(
              id: 'cloud-current',
              name: 'Cloud: current-node',
              updatedAt: DateTime(2026, 4, 5, 9, 5),
            ),
            testProfile(
              id: 'cloud-saved',
              name: 'Cloud: saved-node',
              updatedAt: DateTime(2026, 4, 4, 12, 5),
            ),
            testProfile(
              id: 'manual-a',
              name: 'Manual Tokyo',
              updatedAt: DateTime(2026, 4, 6, 11, 30),
            ),
          ],
          activeProfile: testProfile(
            id: 'cloud-current',
            name: 'Cloud: current-node',
            updatedAt: DateTime(2026, 4, 5, 9, 5),
          ),
        ),
        vpnProvider: TestVpnProvider(status: VpnStatus.disconnected),
      );

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/nodes_workspace_routes.png'),
      );
    });

    testWidgets('captures connected workspace diagnostics state',
        (tester) async {
      await pumpNodesTestApp(
        tester,
        wrapInScaffold: false,
        settle: true,
        surfaceSize: const Size(430, 1900),
        child: const NodesScreen(),
        cloudProvider: TestCloudProvider(
          hasApiKey: true,
          hasApiKeyAfterRefresh: true,
          instances: [
            readyCloudTestInstance(
              label: 'current-node',
              region: 'fra',
              ipv4: '203.0.113.7',
              createdAt: DateTime(2026, 4, 5, 9, 0),
            ),
            readyCloudTestInstance(
              label: 'backup-node',
              region: 'sin',
              ipv4: '198.51.100.33',
              createdAt: DateTime(2026, 4, 4, 12, 0),
            ),
          ],
        ),
        profileProvider: TestProfileProvider(
          profiles: [
            testProfile(
              id: 'cloud-current',
              name: 'Cloud: current-node',
              updatedAt: DateTime(2026, 4, 5, 9, 5),
            ),
            testProfile(
              id: 'manual-a',
              name: 'Manual Tokyo',
              updatedAt: DateTime(2026, 4, 6, 11, 30),
            ),
          ],
          loadedProfiles: [
            testProfile(
              id: 'cloud-current',
              name: 'Cloud: current-node',
              updatedAt: DateTime(2026, 4, 5, 9, 5),
            ),
            testProfile(
              id: 'manual-a',
              name: 'Manual Tokyo',
              updatedAt: DateTime(2026, 4, 6, 11, 30),
            ),
          ],
          activeProfile: testProfile(
            id: 'cloud-current',
            name: 'Cloud: current-node',
            updatedAt: DateTime(2026, 4, 5, 9, 5),
          ),
        ),
        vpnProvider: TestVpnProvider(
          status: VpnStatus.connected,
          stats: TrafficStats(
            uploadBytes: 1024 * 1024 * 3,
            downloadBytes: 1024 * 1024 * 8,
            uploadSpeed: 1024 * 32,
            downloadSpeed: 1024 * 128,
            connectionTime: const Duration(minutes: 12, seconds: 34),
          ),
          diagnosticsEgressIp: '203.0.113.7',
          diagnosticsUpdatedAt: DateTime(2026, 4, 20, 12, 0),
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
      );

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/nodes_workspace_connected.png'),
      );
    });
  });
}

Future<void> _loadGoldenFonts() async {
  // Locate the bundled MaterialIcons font via the live Flutter SDK instead
  // of a hard-coded developer path: `flutter test` exports FLUTTER_ROOT, and
  // on CI the SDK lives somewhere like /opt/hostedtoolcache/flutter, not
  // /home/<user>/flutter. Each font load is best-effort — if a file is
  // absent the loader is skipped so the test still runs with default fonts
  // rather than crashing in setUpAll.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final iconFont = flutterRoot == null
      ? null
      : File(
          '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
  final textFont = File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');

  if (textFont.existsSync()) {
    await (FontLoader('Roboto')
          ..addFont(
              Future.value(textFont.readAsBytesSync().buffer.asByteData())))
        .load();
  }
  if (iconFont != null && iconFont.existsSync()) {
    await (FontLoader('MaterialIcons')
          ..addFont(
              Future.value(iconFont.readAsBytesSync().buffer.asByteData())))
        .load();
  }
}
