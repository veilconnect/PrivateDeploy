import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_vpn_actions.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';

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
  });
}

Future<void> _pumpActionHarness(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onRun,
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
  });

  @override
  final List<CloudInstance> instances;
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

  @override
  String? get error => null;

  @override
  String? getActiveConfigJson() => activeConfigJson;
}

class _FakeVpnProvider extends Fake implements VpnProvider {
  _FakeVpnProvider({
    required VpnStatus status,
    this.isLoading = false,
    this.connectResult = true,
    this.disconnectResult = true,
  }) : _status = status;

  VpnStatus _status;

  @override
  final bool isLoading;

  final bool connectResult;
  final bool disconnectResult;

  @override
  String? get error => null;

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
  Future<bool> connect({String? configJson, String? profileName}) async {
    connectCalls += 1;
    lastConfigJson = configJson;
    lastProfileName = profileName;
    _status = connectResult ? VpnStatus.connected : VpnStatus.disconnected;
    return connectResult;
  }

  @override
  Future<bool> disconnect() async {
    disconnectCalls += 1;
    _status =
        disconnectResult ? VpnStatus.disconnected : VpnStatus.connected;
    return disconnectResult;
  }
}
