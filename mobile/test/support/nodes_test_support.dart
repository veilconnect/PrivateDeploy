import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_config_builder.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_provider_id.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

Future<void> pumpNodesTestApp(
  WidgetTester tester, {
  required Widget child,
  bool settle = false,
  bool wrapInScaffold = true,
  Size surfaceSize = const Size(1440, 2400),
  CloudProvider? cloudProvider,
  ProfileProvider? profileProvider,
  VpnProvider? vpnProvider,
  AppSettingsProvider? appSettingsProvider,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final resolvedAppSettingsProvider =
      appSettingsProvider ?? TestAppSettingsProvider();

  final app = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
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
  String provider = 'vultr',
  String region = 'sgp',
  String plan = 'vc2-1c-1gb',
  String? ipv4 = '1.2.3.4',
  DateTime? createdAt,
}) {
  return testCloudInstance(
    label: label,
    provider: provider,
    region: region,
    plan: plan,
    ipv4: ipv4,
    createdAt: createdAt,
    nodeInfo: defaultTestNodeInfo,
  );
}

CloudInstance testCloudInstance({
  required String label,
  String provider = 'vultr',
  String region = 'sgp',
  String plan = 'vc2-1c-1gb',
  String status = 'active',
  String? ipv4 = '1.2.3.4',
  DateTime? createdAt,
  NodeInfo? nodeInfo,
}) {
  return CloudInstance(
    id: label,
    provider: provider,
    label: label,
    status: status,
    region: region,
    plan: plan,
    ipv4: ipv4,
    createdAt: createdAt ?? DateTime(2026, 3, 29),
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
  String? content,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? lastUpdated,
}) {
  final created = createdAt ?? DateTime(2026, 3, 29, 12, 30);
  return Profile(
    id: id,
    name: name,
    content: content,
    isActive: false,
    createdAt: created,
    updatedAt: updatedAt ?? created,
    lastUpdated: lastUpdated,
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
    this.isLoadingRegions = false,
    this.isLoadingPlans = false,
    this.apiKey,
    Map<String, String>? providerExtra,
    CloudProviderId providerId = CloudProviderId.vultr,
    this.hasPersistedActiveProviderSelection = false,
    this.setApiKeyResult = true,
    this.setSshAccessResult = true,
    this.exportBackupPayload = '{"provider":"vultr"}',
    Map<String, CloudLatencyCheck>? latencyChecks,
    Map<String, String>? preferredEndpointLabels,
    CloudFastestNodeSelection? fastestSelection,
    bool? hasApiKeyAfterRefresh,
    List<CloudInstance>? loadedInstances,
  })  : _hasApiKey = hasApiKey,
        _providerId = providerId,
        _providerExtra = Map<String, String>.from(providerExtra ?? const {}),
        _latencyChecks = latencyChecks ?? const {},
        _preferredEndpointLabels = Map<String, String>.from(
          preferredEndpointLabels ?? const {},
        ),
        _fastestSelection = fastestSelection,
        hasApiKeyAfterRefresh = hasApiKeyAfterRefresh ?? hasApiKey,
        loadedInstances = loadedInstances ?? instances;

  final bool hasApiKeyAfterRefresh;
  final List<CloudInstance> loadedInstances;
  final bool setApiKeyResult;
  final bool setSshAccessResult;
  final String exportBackupPayload;
  bool hasPersistedActiveProviderSelection;

  bool _hasApiKey;
  CloudProviderId _providerId;
  Map<String, String> _providerExtra;
  Map<String, CloudLatencyCheck> _latencyChecks;
  Map<String, String> _preferredEndpointLabels;
  final CloudFastestNodeSelection? _fastestSelection;

  @override
  bool isLoading;

  @override
  bool isLoadingRegions;

  @override
  bool isLoadingPlans;

  @override
  String? error;

  @override
  String? apiKey;

  @override
  String get providerName => _providerId.id;

  @override
  CloudProviderId get providerId => _providerId;

  @override
  bool get isBenchmarkingAll => false;

  @override
  bool get benchmarkAbortRequested => false;

  @override
  List<CloudInstance> instances;

  @override
  List<CloudInstance> get allInstances => instances;

  int refreshCalls = 0;
  int loadInstancesCalls = 0;
  int loadRegionsCalls = 0;
  int loadPlansCalls = 0;
  int clearLocalCloudDataCalls = 0;
  int testInstanceLatencyCalls = 0;
  int setActiveProviderCalls = 0;
  String? savedApiKey;
  String? importedBackupPayload;
  String? importBackupError;

  @override
  bool get hasApiKey => _hasApiKey;

  @override
  bool get hasStoredApiKey => _providerId == CloudProviderId.ssh
      ? _providerExtra['host']?.trim().isNotEmpty == true &&
          _providerExtra['username']?.trim().isNotEmpty == true &&
          _providerExtra['password']?.trim().isNotEmpty == true
      : apiKey?.trim().isNotEmpty == true;

  @override
  Map<String, String> get providerExtra => Map.unmodifiable(_providerExtra);

  @override
  bool get isSshProvider => _providerId == CloudProviderId.ssh;

  @override
  Future<void> refreshCloudConfig({bool notify = true}) async {
    refreshCalls++;
    isLoading = true;
    if (notify) {
      notifyListeners();
    }

    _hasApiKey = _providerId == CloudProviderId.ssh
        ? hasStoredApiKey
        : hasApiKeyAfterRefresh;
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
  Future<void> loadRegions({bool notify = true}) async {
    loadRegionsCalls++;
    isLoadingRegions = false;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  Future<void> loadPlans({bool notify = true}) async {
    loadPlansCalls++;
    isLoadingPlans = false;
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
  Future<bool> setSshAccessConfig({
    required String host,
    required String port,
    required String username,
    required String password,
  }) async {
    if (!setSshAccessResult) {
      error ??= 'Failed to save SSH access';
      notifyListeners();
      return false;
    }
    _providerExtra = <String, String>{
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'authMethod': 'password',
    };
    _hasApiKey = true;
    error = null;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setActiveProvider(CloudProviderId target) async {
    setActiveProviderCalls++;
    _providerId = target;
    hasPersistedActiveProviderSelection = true;
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

  @override
  CloudLatencyCheck? latencyCheckFor(String instanceId) =>
      _latencyChecks[instanceId];

  @override
  List<String> availableEndpointLabelsFor(CloudInstance instance) {
    return availableCloudEndpointLabels(instance.nodeInfo);
  }

  @override
  String? preferredEndpointLabelFor(CloudInstance instance) {
    final label = _preferredEndpointLabels[instance.id];
    return availableEndpointLabelsFor(instance).contains(label) ? label : null;
  }

  @override
  Future<void> setPreferredEndpointLabel(
    CloudInstance instance,
    String? endpointLabel,
  ) async {
    final normalizedLabel = endpointLabel?.trim();
    if (normalizedLabel == null || normalizedLabel.isEmpty) {
      _preferredEndpointLabels.remove(instance.id);
    } else {
      _preferredEndpointLabels[instance.id] = normalizedLabel;
    }
    notifyListeners();
  }

  @override
  Future<CloudLatencyCheck> testInstanceLatency(
    CloudInstance instance, {
    CloudProbeMode mode = CloudProbeMode.quick,
  }) async {
    testInstanceLatencyCalls++;
    final result = _latencyChecks[instance.id] ??
        CloudLatencyCheck.success(
          latencyMs: 42,
          endpointLabel: 'Trojan',
          updatedAt: DateTime(2026, 3, 30, 20, 0),
          mode: mode,
        );
    _latencyChecks = Map<String, CloudLatencyCheck>.from(_latencyChecks)
      ..[instance.id] = result;
    notifyListeners();
    return result;
  }

  @override
  CloudFastestNodeSelection cachedFastestConnectableInstance({
    Duration maxAge = CloudProvider.latencyCacheMaxAge,
  }) {
    return _fastestSelection ??
        const CloudFastestNodeSelection(
          error: 'Latency testing did not return a usable node',
        );
  }

  @override
  Future<CloudFastestNodeSelection> selectFastestConnectableInstance({
    bool forceRefresh = false,
    Duration maxAge = CloudProvider.latencyCacheMaxAge,
  }) async {
    return _fastestSelection ??
        const CloudFastestNodeSelection(
          error: 'Latency testing did not return a usable node',
        );
  }

  @override
  Future<CloudFastestNodeSelection> benchmarkConnectableInstances() async {
    return _fastestSelection ??
        const CloudFastestNodeSelection(
          error: 'No ready cloud node is available for testing',
        );
  }

  @override
  String? generateNodeConfig(CloudInstance instance) {
    return buildCloudNodeConfig(
      instance,
      preferredEndpointLabel: preferredEndpointLabelFor(instance),
      targetPlatform: defaultTargetPlatform,
    );
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
    this.lastKnownEgressIp,
    this.lastKnownEgressIpAt,
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

  @override
  final String? lastKnownEgressIp;

  @override
  final DateTime? lastKnownEgressIpAt;

  VpnStatus _status;
  final List<VpnRouteDecision> _recentRouteDecisions;

  int initializeCalls = 0;
  int loadStatusCalls = 0;
  int disconnectCalls = 0;
  int refreshDiagnosticsCalls = 0;
  int activateDiagnosticsSessionCalls = 0;
  int deactivateDiagnosticsSessionCalls = 0;

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

  @override
  Future<void> activateDiagnosticsSession() async {
    activateDiagnosticsSessionCalls++;
  }

  @override
  Future<void> deactivateDiagnosticsSession() async {
    deactivateDiagnosticsSessionCalls++;
  }
}
