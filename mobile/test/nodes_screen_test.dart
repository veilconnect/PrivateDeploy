import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/nodes/nodes_screen.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NodesScreen', () {
    testWidgets('bootstraps workspace state and renders loaded sections',
        (tester) async {
      final cloudProvider = _TestCloudProvider(
        initialHasApiKey: false,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [_readyInstance(label: 'fra-node')],
      );
      final profileProvider = _TestProfileProvider(
        initialProfiles: const [],
        loadedProfiles: [_profile(id: 'manual-1', name: 'Manual A')],
      );
      final vpnProvider = _TestVpnProvider(
        initialStatus: VpnStatus.disconnected,
        statusAfterInitialize: VpnStatus.disconnected,
      );

      await _pumpNodesScreen(
        tester,
        cloudProvider: cloudProvider,
        profileProvider: profileProvider,
        vpnProvider: vpnProvider,
      );

      expect(find.text('Loading nodes...'), findsOneWidget);

      await tester.pump();
      await tester.pumpAndSettle();

      expect(profileProvider.loadProfilesCalls, 1);
      expect(vpnProvider.initializeCalls, 1);
      expect(vpnProvider.loadStatusCalls, 0);
      expect(cloudProvider.refreshCalls, 1);
      expect(cloudProvider.loadInstancesCalls, 1);
      expect(profileProvider.pruneCalls, 1);

      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Cloud Nodes'), findsOneWidget);
      expect(find.text('Manual Profiles'), findsOneWidget);
      expect(find.text('fra-node'), findsOneWidget);
      expect(find.text('Manual A'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_upload), findsOneWidget);
    });

    testWidgets('refresh uses loadStatus instead of reinitializing vpn',
        (tester) async {
      final cloudProvider = _TestCloudProvider(
        initialHasApiKey: true,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [_readyInstance(label: 'sgp-node')],
      );
      final profileProvider = _TestProfileProvider(
        initialProfiles: const [],
        loadedProfiles: [_profile(id: 'manual-1', name: 'Manual A')],
      );
      final vpnProvider = _TestVpnProvider(
        initialStatus: VpnStatus.disconnected,
        statusAfterInitialize: VpnStatus.disconnected,
        statusAfterLoadStatus: VpnStatus.disconnected,
      );

      await _pumpNodesScreen(
        tester,
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
      final staleProfile = _profile(id: 'cloud-old', name: 'Cloud: old-node');
      final cloudProvider = _TestCloudProvider(
        initialHasApiKey: true,
        hasApiKeyAfterRefresh: true,
        loadedInstances: [_readyInstance(label: 'fresh-node')],
      );
      final profileProvider = _TestProfileProvider(
        initialProfiles: [staleProfile],
        loadedProfiles: [staleProfile],
        activeProfile: staleProfile,
      );
      final vpnProvider = _TestVpnProvider(
        initialStatus: VpnStatus.connected,
        statusAfterInitialize: VpnStatus.connected,
      );

      await _pumpNodesScreen(
        tester,
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
      expect(find.text('Disconnected'), findsOneWidget);
    });
  });
}

Future<void> _pumpNodesScreen(
  WidgetTester tester, {
  required _TestCloudProvider cloudProvider,
  required _TestProfileProvider profileProvider,
  required _TestVpnProvider vpnProvider,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, __) => MultiProvider(
        providers: [
          ChangeNotifierProvider<CloudProvider>.value(value: cloudProvider),
          ChangeNotifierProvider<ProfileProvider>.value(value: profileProvider),
          ChangeNotifierProvider<VpnProvider>.value(value: vpnProvider),
        ],
        child: const MaterialApp(
          home: NodesScreen(),
        ),
      ),
    ),
  );
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
  required String id,
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

class _TestCloudProvider extends ChangeNotifier
    with Fake
    implements CloudProvider {
  _TestCloudProvider({
    required bool initialHasApiKey,
    required this.hasApiKeyAfterRefresh,
    required this.loadedInstances,
    bool initialLoading = true,
  })  : _hasApiKey = initialHasApiKey,
        _isLoading = initialLoading;

  final bool hasApiKeyAfterRefresh;
  final List<CloudInstance> loadedInstances;

  bool _hasApiKey;
  bool _isLoading;
  String? _error;
  List<CloudInstance> _instances = const [];

  int refreshCalls = 0;
  int loadInstancesCalls = 0;

  @override
  bool get hasApiKey => _hasApiKey;

  @override
  bool get isLoading => _isLoading;

  @override
  String? get error => _error;

  @override
  List<CloudInstance> get instances => _instances;

  @override
  Future<void> refreshCloudConfig({bool notify = true}) async {
    refreshCalls++;
    _isLoading = true;
    if (notify) {
      notifyListeners();
    }

    _hasApiKey = hasApiKeyAfterRefresh;
    _error = null;
    _isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> loadInstances({bool notify = true}) async {
    loadInstancesCalls++;
    _instances = List<CloudInstance>.from(loadedInstances);
    if (notify) {
      notifyListeners();
    }
  }
}

class _TestProfileProvider extends ChangeNotifier
    with Fake
    implements ProfileProvider {
  _TestProfileProvider({
    required List<Profile> initialProfiles,
    required this.loadedProfiles,
    this.activeProfile,
    bool initialLoading = true,
  })  : _profiles = List<Profile>.from(initialProfiles),
        _isLoading = initialLoading;

  final List<Profile> loadedProfiles;

  List<Profile> _profiles;
  Profile? activeProfile;
  bool _isLoading;

  int loadProfilesCalls = 0;
  int pruneCalls = 0;
  Set<String>? lastPrunedCloudProfiles;

  @override
  List<Profile> get profiles => _profiles;

  @override
  bool get isLoading => _isLoading;

  @override
  Future<void> loadProfiles() async {
    loadProfilesCalls++;
    _isLoading = true;
    notifyListeners();

    _profiles = List<Profile>.from(loadedProfiles);
    activeProfile = _matchActiveProfile();
    _isLoading = false;
    notifyListeners();
  }

  @override
  Future<int> pruneMissingCloudProfiles(Set<String> existingCloudProfiles) async {
    pruneCalls++;
    lastPrunedCloudProfiles = Set<String>.from(existingCloudProfiles);
    final staleCount = _profiles
        .where(
          (profile) =>
              ProfileProvider.isCloudManagedProfileName(profile.name) &&
              !existingCloudProfiles.contains(profile.name),
        )
        .length;
    _profiles = _profiles
        .where(
          (profile) =>
              !ProfileProvider.isCloudManagedProfileName(profile.name) ||
              existingCloudProfiles.contains(profile.name),
        )
        .toList();

    if (activeProfile != null &&
        ProfileProvider.isCloudManagedProfileName(activeProfile!.name) &&
        !existingCloudProfiles.contains(activeProfile!.name)) {
      activeProfile = null;
    } else {
      activeProfile = _matchActiveProfile();
    }
    notifyListeners();
    return staleCount;
  }

  Profile? _matchActiveProfile() {
    final current = activeProfile;
    if (current == null) {
      return null;
    }

    for (final profile in _profiles) {
      if (profile.id == current.id || profile.name == current.name) {
        return profile;
      }
    }
    return null;
  }
}

class _TestVpnProvider extends ChangeNotifier with Fake implements VpnProvider {
  _TestVpnProvider({
    required VpnStatus initialStatus,
    required this.statusAfterInitialize,
    this.statusAfterLoadStatus,
    TrafficStats? stats,
  })  : _status = initialStatus,
        stats = stats ?? TrafficStats.zero();

  final VpnStatus statusAfterInitialize;
  final VpnStatus? statusAfterLoadStatus;

  VpnStatus _status;

  int initializeCalls = 0;
  int loadStatusCalls = 0;
  int disconnectCalls = 0;

  @override
  VpnStatus get status => _status;

  @override
  final TrafficStats stats;

  @override
  String? get error => null;

  @override
  bool get isSupported => true;

  @override
  bool get isLoading => false;

  @override
  String? get unsupportedReason => null;

  @override
  bool get isConnected => _status == VpnStatus.connected;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _status = statusAfterInitialize;
    notifyListeners();
  }

  @override
  Future<void> loadStatus() async {
    loadStatusCalls++;
    if (statusAfterLoadStatus != null) {
      _status = statusAfterLoadStatus!;
    }
    notifyListeners();
  }

  @override
  Future<bool> disconnect() async {
    disconnectCalls++;
    _status = VpnStatus.disconnected;
    notifyListeners();
    return true;
  }
}
