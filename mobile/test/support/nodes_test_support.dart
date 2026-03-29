import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:provider/provider.dart';

Future<void> pumpNodesTestApp(
  WidgetTester tester, {
  required Widget child,
  bool settle = false,
  bool wrapInScaffold = true,
  CloudProvider? cloudProvider,
  ProfileProvider? profileProvider,
  VpnProvider? vpnProvider,
  AppSettingsProvider? appSettingsProvider,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final resolvedAppSettingsProvider =
      appSettingsProvider ?? TestAppSettingsProvider();

  final app = MaterialApp(
    home: wrapInScaffold ? Scaffold(body: child) : child,
  );

  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, __) {
        final providers = [
          if (cloudProvider != null)
            ChangeNotifierProvider<CloudProvider>.value(value: cloudProvider),
          if (profileProvider != null)
            ChangeNotifierProvider<ProfileProvider>.value(
              value: profileProvider,
            ),
          if (vpnProvider != null)
            ChangeNotifierProvider<VpnProvider>.value(value: vpnProvider),
          ChangeNotifierProvider<AppSettingsProvider>.value(
            value: resolvedAppSettingsProvider,
          ),
        ];
        return MultiProvider(providers: providers, child: app);
      },
    ),
  );

  await tester.pump();
  if (settle) {
    await tester.pumpAndSettle();
  }
}

class TestAppSettingsProvider extends ChangeNotifier
    with Fake
    implements AppSettingsProvider {
  TestAppSettingsProvider({
    VpnRoutingSettings? vpnRoutingSettings,
  }) : _vpnRoutingSettings = vpnRoutingSettings ?? VpnRoutingSettings.defaults;

  VpnRoutingSettings _vpnRoutingSettings;

  @override
  VpnRoutingSettings get vpnRoutingSettings => _vpnRoutingSettings;

  @override
  Future<void> setVpnRoutingMode(VpnRoutingMode mode) async {
    _vpnRoutingSettings = _vpnRoutingSettings.copyWith(mode: mode);
    notifyListeners();
  }

  @override
  Future<void> updateVpnRoutingSettings(VpnRoutingSettings settings) async {
    _vpnRoutingSettings = settings;
    notifyListeners();
  }

  @override
  Future<void> resetVpnRoutingSettings() async {
    _vpnRoutingSettings = VpnRoutingSettings.defaults;
    notifyListeners();
  }
}

CloudInstance readyCloudTestInstance({
  required String label,
}) {
  return testCloudInstance(label: label, nodeInfo: defaultTestNodeInfo);
}

CloudInstance testCloudInstance({
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

const NodeInfo defaultTestNodeInfo = NodeInfo(
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

Profile testProfile({
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

class TestCloudProvider extends ChangeNotifier
    with Fake
    implements CloudProvider {
  TestCloudProvider({
    required bool hasApiKey,
    this.error,
    this.instances = const [],
    this.isLoading = false,
    this.apiKey,
    this.providerName = 'vultr',
    this.setApiKeyResult = true,
    this.exportBackupPayload = '{"provider":"vultr"}',
    bool? hasApiKeyAfterRefresh,
    List<CloudInstance>? loadedInstances,
  })  : _hasApiKey = hasApiKey,
        hasApiKeyAfterRefresh = hasApiKeyAfterRefresh ?? hasApiKey,
        loadedInstances = loadedInstances ?? instances;

  final bool hasApiKeyAfterRefresh;
  final List<CloudInstance> loadedInstances;
  final bool setApiKeyResult;
  final String exportBackupPayload;

  bool _hasApiKey;

  @override
  bool isLoading;

  @override
  String? error;

  @override
  String? apiKey;

  @override
  final String providerName;

  @override
  List<CloudInstance> instances;

  int refreshCalls = 0;
  int loadInstancesCalls = 0;
  int clearLocalCloudDataCalls = 0;
  String? savedApiKey;
  String? importedBackupPayload;
  String? importBackupError;

  @override
  bool get hasApiKey => _hasApiKey;

  @override
  Future<void> refreshCloudConfig({bool notify = true}) async {
    refreshCalls++;
    isLoading = true;
    if (notify) {
      notifyListeners();
    }

    _hasApiKey = hasApiKeyAfterRefresh;
    error = null;
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> loadInstances({bool notify = true}) async {
    loadInstancesCalls++;
    instances = List<CloudInstance>.from(loadedInstances);
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<bool> setApiKey(String key) async {
    savedApiKey = key.trim();
    if (!setApiKeyResult) {
      error ??= 'Failed to save API key';
      notifyListeners();
      return false;
    }

    apiKey = savedApiKey;
    _hasApiKey = true;
    error = null;
    notifyListeners();
    return true;
  }

  @override
  Future<void> clearLocalCloudData() async {
    clearLocalCloudDataCalls++;
    apiKey = null;
    _hasApiKey = false;
    instances = const [];
    notifyListeners();
  }

  @override
  Future<String> exportBackupJson() async {
    return exportBackupPayload;
  }

  @override
  Future<void> importBackupJson(String raw) async {
    importedBackupPayload = raw;
    if (importBackupError != null) {
      throw Exception(importBackupError);
    }
    notifyListeners();
  }
}

class TestProfileProvider extends ChangeNotifier
    with Fake
    implements ProfileProvider {
  TestProfileProvider({
    List<Profile> profiles = const [],
    this.activeProfile,
    this.isLoading = false,
    List<Profile>? loadedProfiles,
  })  : _profiles = List<Profile>.from(profiles),
        loadedProfiles = loadedProfiles ?? profiles;

  final List<Profile> loadedProfiles;

  List<Profile> _profiles;

  @override
  Profile? activeProfile;

  @override
  bool isLoading;

  int loadProfilesCalls = 0;
  int pruneCalls = 0;
  Set<String>? lastPrunedCloudProfiles;

  @override
  List<Profile> get profiles => _profiles;

  @override
  Future<void> loadProfiles() async {
    loadProfilesCalls++;
    isLoading = true;
    notifyListeners();

    _profiles = List<Profile>.from(loadedProfiles);
    activeProfile = _matchActiveProfile();
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<int> pruneMissingCloudProfiles(
      Set<String> existingCloudProfiles) async {
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

class TestVpnProvider extends ChangeNotifier with Fake implements VpnProvider {
  TestVpnProvider({
    required VpnStatus status,
    VpnStatus? statusAfterInitialize,
    this.statusAfterLoadStatus,
    this.error,
    this.isSupported = true,
    this.isLoading = false,
    this.unsupportedReason,
    TrafficStats? stats,
    this.diagnosticsEgressIp,
    this.diagnosticsError,
    this.isRefreshingDiagnostics = false,
    this.diagnosticsUpdatedAt,
    List<VpnRouteDecision>? recentRouteDecisions,
  })  : _status = status,
        statusAfterInitialize = statusAfterInitialize ?? status,
        stats = stats ?? TrafficStats.zero(),
        _recentRouteDecisions =
            List<VpnRouteDecision>.from(recentRouteDecisions ?? const []);

  final VpnStatus statusAfterInitialize;
  final VpnStatus? statusAfterLoadStatus;

  @override
  final String? error;

  @override
  final bool isSupported;

  @override
  final bool isLoading;

  @override
  final String? unsupportedReason;

  @override
  final String? diagnosticsEgressIp;

  @override
  final String? diagnosticsError;

  @override
  final bool isRefreshingDiagnostics;

  @override
  final DateTime? diagnosticsUpdatedAt;

  VpnStatus _status;
  final List<VpnRouteDecision> _recentRouteDecisions;

  int initializeCalls = 0;
  int loadStatusCalls = 0;
  int disconnectCalls = 0;
  int refreshDiagnosticsCalls = 0;

  @override
  VpnStatus get status => _status;

  @override
  final TrafficStats stats;

  @override
  bool get isConnected => _status == VpnStatus.connected;

  @override
  List<VpnRouteDecision> get recentRouteDecisions =>
      List<VpnRouteDecision>.unmodifiable(_recentRouteDecisions);

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

  @override
  Future<void> refreshDiagnostics() async {
    refreshDiagnosticsCalls++;
    notifyListeners();
  }
}
