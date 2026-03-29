import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_cloud_actions.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_config_validation.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_sections.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

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
      expect(cloudProfileName(_readyInstance(label: 'sgp-1')), 'Cloud: sgp-1');
    });

    test('connectableCloudInstances returns only active nodes with ip and creds',
        () {
      final provider = _FakeCloudProvider(
        hasApiKey: true,
        instances: [
          _readyInstance(label: 'ready-1'),
          _readyInstance(label: 'ready-2'),
          _instance(label: 'pending', status: 'installing'),
          _instance(label: 'missing-ip', ipv4: null),
          _instance(label: 'missing-creds', nodeInfo: null),
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
      await _pumpNodeTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: _FakeVpnProvider(
            status: VpnStatus.connecting,
            isLoading: true,
          ),
          profileProvider: _FakeProfileProvider(),
          cloudProvider: _FakeCloudProvider(hasApiKey: true),
          onConnect: () {},
          onDisconnect: () {},
          onRestart: () {},
        ),
      );

      expect(find.text('Processing VPN...'), findsOneWidget);
    });

    testWidgets('shows unsupported native VPN notice when runtime is unavailable',
        (tester) async {
      await _pumpNodeTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: _FakeVpnProvider(
            status: VpnStatus.disconnected,
            isSupported: false,
            unsupportedReason: 'Native core missing',
          ),
          profileProvider: _FakeProfileProvider(),
          cloudProvider: _FakeCloudProvider(hasApiKey: true),
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

      await _pumpNodeTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          profileProvider: _FakeProfileProvider(),
          cloudProvider: _FakeCloudProvider(
            hasApiKey: true,
            instances: [_readyInstance(label: 'ready-node')],
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

      await _pumpNodeTestApp(
        tester,
        child: NodesVpnSection(
          vpnProvider: _FakeVpnProvider(
            status: VpnStatus.connected,
            stats: TrafficStats(
              uploadBytes: 1024,
              downloadBytes: 2048,
              uploadSpeed: 128,
              downloadSpeed: 256,
              connectionTime: const Duration(minutes: 5),
            ),
          ),
          profileProvider: _FakeProfileProvider(
            activeProfile: _profile(name: 'Cloud: ready-node'),
          ),
          cloudProvider: _FakeCloudProvider(hasApiKey: true),
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

      await _pumpNodeTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: _FakeCloudProvider(
            hasApiKey: true,
            error: 'boom',
          ),
          profileProvider: _FakeProfileProvider(),
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () {},
          onRetryLoad: () => retryTapped = true,
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
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

      await _pumpNodeTestApp(
        tester,
        child: NodesCloudSection(
          cloudProvider: _FakeCloudProvider(hasApiKey: false),
          profileProvider: _FakeProfileProvider(),
          vpnProvider: _FakeVpnProvider(status: VpnStatus.disconnected),
          onConfigureApiKey: () => configureTapped = true,
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (_) {},
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (_) {},
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

      await _pumpNodeTestApp(
        tester,
        settle: true,
        child: NodesCloudSection(
          cloudProvider: _FakeCloudProvider(
            hasApiKey: true,
            instances: [_readyInstance(label: 'fra-node')],
          ),
          profileProvider: _FakeProfileProvider(
            profiles: [_profile(name: 'Cloud: fra-node')],
            activeProfile: _profile(name: 'Cloud: fra-node'),
          ),
          vpnProvider: _FakeVpnProvider(status: VpnStatus.connected),
          onConfigureApiKey: () {},
          onRetryLoad: () {},
          onCreateCloudNode: () {},
          onViewDetails: (instance) => detailedNode = instance,
          onDeleteCloudNode: (_) {},
          onUseCloudNode: (instance) => usedNode = instance,
        ),
      );

      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('Active Node'), findsOneWidget);
      expect(find.text('IN USE'), findsOneWidget);

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

      await _pumpNodeTestApp(
        tester,
        settle: true,
        child: NodesManualProfilesSection(
          profiles: [
            _profile(id: '1', name: 'Manual A'),
            _profile(id: '2', name: 'Manual B'),
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

Future<void> _pumpNodeTestApp(
  WidgetTester tester, {
  required Widget child,
  bool settle = false,
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
        return MaterialApp(
          home: Scaffold(body: child),
        );
      },
    ),
  );
  await tester.pump();
  if (settle) {
    await tester.pumpAndSettle();
  }
}

CloudInstance _readyInstance({
  required String label,
}) {
  return _instance(label: label, nodeInfo: _defaultNodeInfo);
}

CloudInstance _instance({
  required String label,
  String status = 'active',
  String? ipv4 = '1.2.3.4',
  NodeInfo? nodeInfo,
}) {
  return CloudInstance(
    id: label,
    provider: 'vultr',
    label: label,
    status: status,
    region: 'sgp',
    plan: 'vc2-1c-1gb',
    ipv4: ipv4,
    createdAt: DateTime(2026, 3, 29),
    nodeInfo: nodeInfo,
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
    required this.hasApiKey,
    this.error,
    this.instances = const [],
  });

  @override
  final bool hasApiKey;

  @override
  final String? error;

  @override
  final List<CloudInstance> instances;
}

class _FakeProfileProvider extends Fake implements ProfileProvider {
  _FakeProfileProvider({
    this.profiles = const [],
    this.activeProfile,
  });

  @override
  final List<Profile> profiles;

  @override
  final Profile? activeProfile;
}

class _FakeVpnProvider extends Fake implements VpnProvider {
  _FakeVpnProvider({
    required this.status,
    this.isSupported = true,
    this.isLoading = false,
    this.unsupportedReason,
    TrafficStats? stats,
  }) : stats = stats ?? TrafficStats.zero();

  @override
  final VpnStatus status;

  @override
  final bool isSupported;

  @override
  final bool isLoading;

  @override
  final String? unsupportedReason;

  @override
  final TrafficStats stats;

  @override
  bool get isConnected => status == VpnStatus.connected;
}
