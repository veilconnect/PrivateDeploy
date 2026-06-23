import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../shared/utils/logger.dart';
import '../../core/storage/storage_service.dart';
import '../profiles/profile_provider.dart';
import 'cloud_api_client.dart';
import 'cloud_backup.dart';
import 'cloud_node_config_builder.dart';
import 'cloud_node_record.dart';
import 'cloud_models.dart';
import 'cloud_provider_base.dart';
import 'cloud_provider_id.dart';
import 'cloud_provider_utils.dart';
import 'cloud_provider_validation.dart';
import 'digitalocean_client.dart';
import 'ssh_deployer.dart';
import 'vultr_deploy.dart';
import 'vultr_client.dart';
import 'vultr_region_latency.dart';
import 'vultr_user_data_recovery.dart';

typedef CloudLatencyProbe = Future<CloudLatencyCheck> Function(
    CloudInstance instance);

class CloudProvider extends CloudProviderBase {
  CloudProviderId _providerId = CloudProviderId.vultr;
  bool _hasPersistedActiveProviderSelection = false;

  @override
  CloudProviderId get providerId => _providerId;

  bool get hasPersistedActiveProviderSelection =>
      _hasPersistedActiveProviderSelection;

  static const String _activeProviderStorageKey =
      'mobile_cloud_active_provider';
  static const String _preferredEndpointStorageKey =
      'mobile_cloud_endpoint_preferences';
  static const String _regionLatencyStorageKey =
      'mobile_cloud_region_latency_v1';
  static const Duration latencyCacheMaxAge = Duration(minutes: 5);
  // How long a persisted region-latency reading is worth showing on a cold
  // dialog open before we'd rather show nothing. A re-probe refreshes whatever
  // survives within ~1.5s of the dialog opening, so this only governs the
  // brief pre-refresh display.
  static const Duration regionLatencyPersistMaxAge = Duration(days: 3);
  static const Duration connectSelectionReuseMaxAge = Duration(minutes: 30);
  static const Duration quickProbeTimeout = Duration(milliseconds: 900);
  static const Duration benchmarkProbeTimeout = Duration(milliseconds: 1500);
  static const int benchmarkProbeSamplesPerEndpoint = 3;
  static const Duration _pendingPollInterval = Duration(seconds: 12);
  static const Duration _pendingPollMaxDuration = Duration(minutes: 30);

  List<CloudInstance> _instances = [];
  List<CloudRegion> _regions = [];
  List<CloudPlan> _plans = [];
  bool _isLoading = false;
  bool _configLoaded = false;
  bool _hasApiKey = false;
  bool _isLoadingRegions = false;
  bool _isLoadingPlans = false;
  String? _error;
  String? _apiKey;
  CloudAccountStatus? _accountStatus;
  Map<String, String> _providerExtra = {};
  final String _selectedProfile = PortProfileAllocator.edge443Profile;
  Map<String, VultrNodeRecord> _nodeRecords = {};
  final Map<String, CloudLatencyCheck> _latencyChecks = {};
  // Per-region reachability/latency to Vultr's public anchor IPs, keyed by
  // region code. Drives the deploy dialog's "which region is usable" hints.
  // Distinct from _latencyChecks (which is per deployed instance).
  final Map<String, CloudLatencyCheck> _regionLatencyChecks = {};
  bool _isProbingRegions = false;
  final Map<String, String> _preferredEndpointLabels = {};
  Future<void>? _regionsLoadFuture;
  Future<void>? _plansLoadFuture;
  final CloudLatencyProbe _latencyProbe;
  final CloudLatencyProbe _benchmarkLatencyProbe;
  final RegionLatencyProbe _regionLatencyProbe;
  bool _benchmarkAllRunning = false;
  bool _benchmarkAbortRequested = false;
  int _providerRequestEpoch = 0;
  // Cached CloudInstance lists for providers OTHER than the active one, so
  // the UI can show all nodes from every configured provider in one list.
  // Populated by loadInstances alongside the active provider's live fetch.
  final Map<CloudProviderId, List<CloudInstance>> _otherProviderInstances = {};
  // Nodes a successful provider API list call confirmed are gone, but a local
  // cached record still references. Kept (flagged), never auto-deleted — the
  // user is prompted and only a confirm removes them. Re-derived each refresh.
  List<CloudInstance> _missingInstances = [];
  // Ids already surfaced in the "confirmed deleted" prompt this session, so we
  // don't nag on every refresh after the user chose to keep them.
  final Set<String> _missingPrompted = {};
  Timer? _pendingPollTimer;
  DateTime? _pendingPollStartedAt;
  bool _disposed = false;

  List<CloudInstance> get instances => _instances;

  /// Nodes confirmed deleted upstream (via the provider key) but still cached
  /// locally. Surfaced flagged in [allInstances]; removed only on user confirm.
  List<CloudInstance> get missingInstances =>
      List.unmodifiable(_missingInstances);

  /// Confirmed-missing nodes the user hasn't yet been prompted about this
  /// session. Drives the one-time "remove deleted nodes?" prompt.
  List<CloudInstance> get unpromptedMissingInstances => _missingInstances
      .where((instance) => !_missingPrompted.contains(instance.id))
      .toList();

  /// Mark every current confirmed-missing node as already prompted, so the
  /// removal prompt isn't shown again until a newly-deleted node appears.
  void markMissingPrompted() {
    _missingPrompted.addAll(_missingInstances.map((instance) => instance.id));
  }

  /// Merged view: active provider's live instances + cached instances from
  /// every other configured provider. Deduped by id; sorted newest-first.
  List<CloudInstance> get allInstances {
    final merged = <String, CloudInstance>{};
    for (final inst in _instances) {
      merged[inst.id] = inst;
    }
    for (final other in _otherProviderInstances.values) {
      for (final inst in other) {
        merged.putIfAbsent(inst.id, () => inst);
      }
    }
    // Confirmed-deleted nodes still pending the user's removal decision are
    // shown flagged alongside the live ones (and override any stale cached
    // copy of the same id from the merge above).
    for (final inst in _missingInstances) {
      merged[inst.id] = inst;
    }
    final list = merged.values.toList()
      ..sort((a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    return list;
  }

  List<CloudRegion> get regions => _regions;
  List<CloudPlan> get plans => _plans;
  bool get isLoading => _isLoading;
  bool get configLoaded => _configLoaded;
  bool get isLoadingRegions => _isLoadingRegions;
  bool get isLoadingPlans => _isLoadingPlans;
  bool get isBenchmarkingAll => _benchmarkAllRunning;
  bool get benchmarkAbortRequested => _benchmarkAbortRequested;
  String? get error => _error;
  Map<String, String> get providerExtra => Map.unmodifiable(_providerExtra);
  bool get isSshProvider => _providerId == CloudProviderId.ssh;

  /// Most-recent upstream account-status probe for the active provider.
  /// `null` means we haven't probed yet (or the provider doesn't expose
  /// account status — SSH). UI banners gate on this; the deploy button is
  /// only blocked when [accountStatus?.canDeploy] is `false`.
  CloudAccountStatus? get accountStatus => _accountStatus;

  /// Probes the active provider's account-status endpoint and stores the
  /// result so callers can render the locked/warning banner. Fire-and-forget
  /// safe: any failure is captured as state=unknown so the UI fails open.
  Future<CloudAccountStatus?> refreshAccountStatus() async {
    if (isSshProvider) {
      _accountStatus = null;
      return null;
    }
    if (!_hasApiKey || (_apiKey ?? '').trim().isEmpty) {
      _accountStatus = null;
      return null;
    }
    try {
      final client = await _cloudClient();
      final status = await client.getAccountStatus();
      _accountStatus = status;
      notifyListeners();
      return status;
    } catch (e) {
      _accountStatus = CloudAccountStatus.unknown(
          'Account-status probe failed: ${cloudProviderMessageFromError(e)}');
      notifyListeners();
      return _accountStatus;
    }
  }

  void markBenchmarkAllStart() {
    _benchmarkAllRunning = true;
    _benchmarkAbortRequested = false;
    notifyListeners();
  }

  void markBenchmarkAllEnd() {
    _benchmarkAllRunning = false;
    _benchmarkAbortRequested = false;
    notifyListeners();
  }

  void requestBenchmarkAllAbort() {
    if (!_benchmarkAllRunning || _benchmarkAbortRequested) return;
    _benchmarkAbortRequested = true;
    notifyListeners();
  }

  bool get hasApiKey => _hasApiKey;
  String? get apiKey => _apiKey;
  bool get hasStoredApiKey => isSshProvider
      ? hasValidSshAccessConfig(_providerExtra)
      : _apiKey?.trim().isNotEmpty == true;
  bool get isConfigured => _hasApiKey && _configLoaded;
  CloudLatencyCheck? latencyCheckFor(String instanceId) =>
      _latencyChecks[instanceId];

  List<String> availableEndpointLabelsFor(CloudInstance instance) {
    return availableCloudEndpointLabels(instance.nodeInfo);
  }

  String? preferredEndpointLabelFor(CloudInstance instance) {
    final preferenceKey = _endpointPreferenceKeyForInstance(instance);
    final preferredLabel = _preferredEndpointLabels[preferenceKey]?.trim();
    if (preferredLabel == null || preferredLabel.isEmpty) {
      return null;
    }

    return availableEndpointLabelsFor(instance).contains(preferredLabel)
        ? preferredLabel
        : null;
  }

  Future<void> setPreferredEndpointLabel(
    CloudInstance instance,
    String? endpointLabel,
  ) async {
    await _initializeStorage();

    final preferenceKey = _endpointPreferenceKeyForInstance(instance);
    final normalizedLabel = endpointLabel?.trim();
    if (normalizedLabel == null || normalizedLabel.isEmpty) {
      _preferredEndpointLabels.remove(preferenceKey);
    } else {
      final availableLabels = availableEndpointLabelsFor(instance);
      if (!availableLabels.contains(normalizedLabel)) {
        throw ArgumentError.value(
          endpointLabel,
          'endpointLabel',
          'Endpoint is not available for this node',
        );
      }
      _preferredEndpointLabels[preferenceKey] = normalizedLabel;
    }

    await _persistPreferredEndpointLabels();
    notifyListeners();
  }

  String? resolveEgressIpForProfileName(String? profileName) {
    final label = _cloudInstanceLabelFromProfileName(profileName);
    if (label == null) {
      return null;
    }

    final instance =
        _instances.where((candidate) => candidate.label == label).firstOrNull;
    final instanceIp = _preferredPublicIp(instance?.ipv4, instance?.ipv6);
    if (instanceIp != null) {
      return instanceIp;
    }

    final record = _nodeRecords.values
        .where((candidate) => candidate.label == label)
        .firstOrNull;
    return _preferredPublicIp(record?.ipv4, record?.ipv6);
  }

  /// Reverse of [resolveEgressIpForProfileName]: given an observed egress IP
  /// (e.g. what api.ipify returned through the tunnel), find which known
  /// cloud node owns it. Used to surface "via X" labels when sing-box's
  /// urltest pool routes through a non-primary node — the connection header
  /// would otherwise still show the user-selected profile name even though
  /// traffic is actually exiting through a failover member.
  ///
  /// Returns null if no known node matches (e.g. the user is going through
  /// a Cloudflare worker so the egress is a CF edge IP), in which case the
  /// caller should just show the raw IP without a "via" label.
  CloudInstance? findCloudInstanceByEgressIp(String? egressIp) {
    if (egressIp == null) return null;
    final trimmed = egressIp.trim();
    if (trimmed.isEmpty) return null;
    for (final inst in _instances) {
      if (inst.ipv4 == trimmed || inst.ipv6 == trimmed) {
        return inst;
      }
    }
    return null;
  }

  @visibleForTesting
  static String normalizeInstanceLabel(String? raw, {DateTime? now}) {
    return normalizeCloudInstanceLabel(raw, now: now);
  }

  @visibleForTesting
  static String? validateDeploymentSelection({
    required String region,
    required String plan,
    required List<CloudRegion> regions,
    required List<CloudPlan> plans,
  }) {
    return validateCloudDeploymentSelection(
      region: region,
      plan: plan,
      regions: regions,
      plans: plans,
    );
  }

  @visibleForTesting
  static String redeployInstanceLabel(String? raw, {DateTime? now}) {
    final base = normalizeInstanceLabel(raw, now: now);
    final ts = now ?? DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final suffix =
        '${two(ts.month)}${two(ts.day)}${two(ts.hour)}${two(ts.minute)}';
    return '$base-redeploy-$suffix';
  }

  @visibleForTesting
  static String? findReplacementRecordId({
    required String instanceId,
    required String label,
    required String region,
    required String ipv4,
    required String ipv6,
    required Map<String, VultrNodeRecord> knownRecords,
    required Set<String> liveInstanceIds,
    Set<String>? claimedRecordIds,
  }) {
    return _findReplacementNodeRecordId(
      instanceId: instanceId,
      label: label,
      region: region,
      ipv4: ipv4,
      ipv6: ipv6,
      knownRecords: knownRecords,
      liveInstanceIds: liveInstanceIds,
      claimedRecordIds: claimedRecordIds ?? <String>{},
    );
  }

  @visibleForTesting
  static VultrNodeRecord prepareReplacementRecord({
    required VultrNodeRecord record,
    required String instanceId,
    required String label,
    required String region,
    required String plan,
    required String ipv4,
    required String ipv6,
    required String createdAt,
  }) {
    return _prepareReplacementNodeRecord(
      record: record,
      instanceId: instanceId,
      label: label,
      region: region,
      plan: plan,
      ipv4: ipv4,
      ipv6: ipv6,
      createdAt: createdAt,
    );
  }

  CloudProvider({
    CloudLatencyProbe? latencyProbe,
    CloudLatencyProbe? benchmarkLatencyProbe,
    RegionLatencyProbe? regionLatencyProbe,
    bool autoInitialize = true,
  })  : _latencyProbe = latencyProbe ?? _defaultLatencyProbe,
        _benchmarkLatencyProbe =
            benchmarkLatencyProbe ?? _defaultBenchmarkLatencyProbe,
        _regionLatencyProbe = regionLatencyProbe ?? probeVultrRegionLatency {
    if (autoInitialize) {
      _init();
    }
  }

  static String? _cloudInstanceLabelFromProfileName(String? profileName) {
    final trimmedName = profileName?.trim();
    if (trimmedName == null ||
        trimmedName.isEmpty ||
        !ProfileProvider.isCloudManagedProfileName(trimmedName)) {
      return null;
    }

    final label = trimmedName
        .substring(ProfileProvider.cloudManagedProfilePrefix.length)
        .trim();
    return label.isEmpty ? null : label;
  }

  static String? _preferredPublicIp(String? ipv4, String? ipv6) {
    final normalizedIpv4 = ipv4?.trim();
    if (normalizedIpv4 != null &&
        normalizedIpv4.isNotEmpty &&
        normalizedIpv4 != '0.0.0.0') {
      return normalizedIpv4;
    }

    final normalizedIpv6 = ipv6?.trim();
    if (normalizedIpv6 != null && normalizedIpv6.isNotEmpty) {
      return normalizedIpv6;
    }
    return null;
  }

  Future<void> _init() async {
    await _initializeStorage();
    await _restorePreferredEndpointLabels();
    // Rehydrate last-known region reachability so the deploy dialog shows
    // numbers immediately on a cold open instead of a spinner; a re-probe on
    // open refreshes them.
    await _restoreRegionLatencies();
    // Restore the previously selected provider before loading any per-provider
    // data, otherwise node records and api key would be read from the wrong
    // storage namespace on app restart.
    await _restorePersistedActiveProvider();
    await _loadNodeRecords();
    // Immediately build the instances list from cached node records so the UI
    // can display known nodes without waiting for a network round-trip.
    _restoreInstancesFromCache();
    await _loadOtherProviderInstancesFromCache();
    // Load the API key from local storage so hasApiKey is accurate without
    // waiting for a network round-trip.  The full cloud config refresh (which
    // validates the key against the remote API) is deferred to the first
    // workspace sync triggered by NodesScreen, avoiding a blocking network
    // call during provider construction.
    _apiKey = await _getStoredApiKey();
    _providerExtra = await _getStoredProviderExtra();
    _hasApiKey = _hasStoredAccessFor(_providerId, _apiKey, _providerExtra);
    _configLoaded = true;
    notifyListeners();
  }

  Future<void> _restorePersistedActiveProvider() async {
    final stored = StorageService.getString(_activeProviderStorageKey);
    final parsed = CloudProviderId.tryParse(stored);
    if (parsed != null) {
      _providerId = parsed;
      _hasPersistedActiveProviderSelection = true;
    }
  }

  Future<void> _restorePreferredEndpointLabels() async {
    _preferredEndpointLabels.clear();
    final raw = StorageService.getString(_preferredEndpointStorageKey);
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }

      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value?.toString().trim() ?? '';
        if (key.isEmpty || value.isEmpty) {
          continue;
        }
        _preferredEndpointLabels[key] = value;
      }
    } catch (e) {
      AppLogger.error(
        '[CloudProvider] Failed to parse preferred endpoint labels',
        e,
      );
      await StorageService.remove(_preferredEndpointStorageKey);
    }
  }

  Future<void> _persistPreferredEndpointLabels() async {
    if (_preferredEndpointLabels.isEmpty) {
      await StorageService.remove(_preferredEndpointStorageKey);
      return;
    }
    await StorageService.saveString(
      _preferredEndpointStorageKey,
      jsonEncode(_preferredEndpointLabels),
    );
  }

  /// Restore last-known per-region reachability/latency from disk so a cold
  /// deploy-dialog open shows numbers immediately. Entries older than
  /// [regionLatencyPersistMaxAge] are dropped; the on-open re-probe refreshes
  /// whatever survives. Stored compactly as `{regionId: {ms|err, ts}}`.
  Future<void> _restoreRegionLatencies() async {
    _regionLatencyChecks.clear();
    final raw = StorageService.getString(_regionLatencyStorageKey);
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final now = DateTime.now();
      for (final entry in decoded.entries) {
        final regionId = entry.key.toString();
        final value = entry.value;
        if (regionId.isEmpty || value is! Map) {
          continue;
        }
        final tsRaw = value['ts'];
        final ts = tsRaw is int ? tsRaw : int.tryParse('$tsRaw');
        if (ts == null) {
          continue;
        }
        final updatedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        if (now.difference(updatedAt) > regionLatencyPersistMaxAge) {
          continue;
        }
        final msRaw = value['ms'];
        final ms = msRaw is int ? msRaw : int.tryParse('${msRaw ?? ''}');
        _regionLatencyChecks[regionId] = ms != null
            ? CloudLatencyCheck.success(latencyMs: ms, updatedAt: updatedAt)
            : CloudLatencyCheck.failure(
                error: 'unreachable',
                updatedAt: updatedAt,
              );
      }
    } catch (e) {
      AppLogger.error('[CloudProvider] Failed to parse region latencies', e);
      await StorageService.remove(_regionLatencyStorageKey);
    }
  }

  Future<void> _persistRegionLatencies() async {
    if (!StorageService.isInitialized) {
      return;
    }
    final serializable = <String, Map<String, int>>{};
    _regionLatencyChecks.forEach((regionId, check) {
      if (check.isTesting) {
        return;
      }
      final ts = (check.updatedAt ?? DateTime.now()).millisecondsSinceEpoch;
      final ms = check.latencyMs;
      serializable[regionId] =
          ms != null ? {'ms': ms, 'ts': ts} : {'err': 1, 'ts': ts};
    });
    if (serializable.isEmpty) {
      await StorageService.remove(_regionLatencyStorageKey);
      return;
    }
    await StorageService.saveString(
      _regionLatencyStorageKey,
      jsonEncode(serializable),
    );
  }

  String _endpointPreferenceKeyForInstance(CloudInstance instance) {
    final owner = CloudProviderId.tryParse(instance.provider) ?? _providerId;
    return '${owner.id}:${instance.id}';
  }

  /// Switch the active cloud provider. Keeps both providers' persisted data
  /// intact (storage keys are namespaced via CloudProviderId) — the
  /// inactive provider's nodes simply aren't shown until it becomes active
  /// again. Returns false if already on [target] or still mid-init.
  Future<bool> setActiveProvider(CloudProviderId target) async {
    if (_providerId == target) {
      return false;
    }
    await _initializeStorage();
    _providerRequestEpoch += 1;
    _providerId = target;
    _hasPersistedActiveProviderSelection = true;
    await StorageService.saveString(_activeProviderStorageKey, target.id);

    // Reset in-memory state tied to the previous provider. Disk records
    // remain under the old provider's storage keys and will rehydrate when
    // the user switches back.
    _instances = const [];
    _regions = const [];
    _plans = const [];
    _nodeRecords = {};
    _latencyChecks.clear();
    _isLoading = false;
    _isLoadingRegions = false;
    _isLoadingPlans = false;
    _regionsLoadFuture = null;
    _plansLoadFuture = null;
    _apiKey = null;
    _providerExtra = {};
    _hasApiKey = false;
    _configLoaded = false;
    _error = null;
    _accountStatus = null;

    await _loadNodeRecords();
    _restoreInstancesFromCache();
    await _loadOtherProviderInstancesFromCache();
    _apiKey = await _getStoredApiKey();
    _providerExtra = await _getStoredProviderExtra();
    _hasApiKey = _hasStoredAccessFor(_providerId, _apiKey, _providerExtra);
    notifyListeners();
    return true;
  }

  /// Populate [_instances] from locally persisted [_nodeRecords] so the UI
  /// renders cached nodes instantly, before any API call completes.
  void _restoreInstancesFromCache() {
    if (_nodeRecords.isEmpty) return;
    final cached = _nodeRecords.values
        .where((r) => r.instanceId.isNotEmpty && r.isUsable)
        .map((record) => record.toCloudInstance())
        .toList()
      ..sort(
        (a, b) =>
            (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
    if (cached.isNotEmpty) {
      _instances = cached;
    }
  }

  Future<void> _initializeStorage() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
  }

  Future<CloudApiClient> _cloudClient() async {
    if (isSshProvider) {
      throw StateError('SSH provider does not use a cloud API client');
    }
    final key = await _getStoredApiKey();
    if (key == null || key.isEmpty) {
      throw StateError('${providerDisplayName} API key is not configured');
    }
    return _buildClient(_providerId, key);
  }

  /// Build a one-off client for any provider id + key. Used for cross-
  /// provider actions (e.g. deleting a node from the non-active provider's
  /// list) without disturbing the current active-provider state.
  CloudApiClient _buildClient(CloudProviderId id, String key) {
    switch (id) {
      case CloudProviderId.digitalocean:
        return DigitalOceanCloudClient(key);
      case CloudProviderId.vultr:
        return VultrCloudClient(key);
      case CloudProviderId.ssh:
        throw UnsupportedError(
            'SSH provider does not build a cloud API client');
    }
  }

  Future<CloudApiClient?> _clientForProvider(CloudProviderId id) async {
    final key = await StorageService.getSecureString(id.apiKeyStorageKey) ??
        StorageService.getString(id.apiKeyStorageKey);
    if (key == null || key.isEmpty) return null;
    return _buildClient(id, key);
  }

  Future<String?> _getStoredApiKey() async {
    return _getStoredApiKeyFor(_providerId);
  }

  Future<Map<String, String>> _getStoredProviderExtra() async {
    return _getStoredProviderExtraFor(_providerId);
  }

  Future<String?> _getStoredApiKeyFor(CloudProviderId providerId) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    var key = await StorageService.getSecureString(providerId.apiKeyStorageKey);
    if (key == null || key.isEmpty) {
      final legacy = StorageService.getString(providerId.apiKeyStorageKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        key = legacy.trim();
        final savedSecurely = await StorageService.saveSecureString(
          providerId.apiKeyStorageKey,
          key,
        );
        if (savedSecurely) {
          await StorageService.remove(providerId.apiKeyStorageKey);
        }
      }
    }

    final normalized = key?.trim();
    if (_providerId == providerId) {
      _apiKey = (normalized == null || normalized.isEmpty) ? null : normalized;
    }
    return (normalized == null || normalized.isEmpty) ? null : normalized;
  }

  Future<Map<String, String>> _getStoredProviderExtraFor(
    CloudProviderId providerId,
  ) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    var raw = await StorageService.getSecureString(providerId.configStorageKey);
    if (raw == null || raw.isEmpty) {
      final legacy = StorageService.getString(providerId.configStorageKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        raw = legacy.trim();
        final savedSecurely = await StorageService.saveSecureString(
          providerId.configStorageKey,
          raw,
        );
        if (savedSecurely) {
          await StorageService.remove(providerId.configStorageKey);
        }
      }
    }
    if (raw == null || raw.isEmpty) {
      if (_providerId == providerId) {
        _providerExtra = {};
      }
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final parsed = decoded.map<String, String>(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        );
        if (_providerId == providerId) {
          _providerExtra = parsed;
        }
        return parsed;
      }
    } catch (error) {
      AppLogger.error(
        '[CloudProvider] Failed to parse stored provider config for ${providerId.id}',
        error,
      );
    }
    if (_providerId == providerId) {
      _providerExtra = {};
    }
    return {};
  }

  // Persist a new key and mark cloud access as available. Keep these flags
  // in sync inside the helper so callers (importBackupJson, setApiKey, etc.)
  // cannot drift — historically importBackupJson called _saveApiKey but
  // forgot to set _hasApiKey, leaving Workspace stuck on the empty state
  // until the app was restarted.
  // Returns false when the secret could not be stored in the keystore. Secure
  // storage is now fail-closed (no plaintext fallback), so in-memory flags are
  // only flipped on a successful persist — the UI must never claim a key is
  // saved when it would be lost on restart.
  Future<bool> _saveApiKey(String key) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    final normalized = key.trim();
    final savedSecurely =
        await StorageService.saveSecureString(apiKeyStorageKey, normalized);
    if (!savedSecurely) {
      return false;
    }
    _apiKey = normalized;
    _hasApiKey = _apiKey!.isNotEmpty;
    return true;
  }

  Future<bool> _saveProviderExtra(Map<String, String> extra) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    final normalized = Map<String, String>.from(extra);
    final savedSecurely = await StorageService.saveSecureString(
      providerId.configStorageKey,
      jsonEncode(normalized),
    );
    if (!savedSecurely) {
      return false;
    }
    _providerExtra = normalized;
    return true;
  }

  Future<void> _clearApiKey() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = null;
    _hasApiKey = false;
    await StorageService.removeSecure(apiKeyStorageKey);
    await StorageService.remove(apiKeyStorageKey);
  }

  Future<void> _clearProviderExtra() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _providerExtra = {};
    await StorageService.removeSecure(providerId.configStorageKey);
    await StorageService.remove(providerId.configStorageKey);
  }

  bool _hasStoredAccessFor(
    CloudProviderId providerId,
    String? apiKey,
    Map<String, String> extra,
  ) {
    switch (providerId) {
      case CloudProviderId.ssh:
        return hasValidSshAccessConfig(extra);
      case CloudProviderId.vultr:
      case CloudProviderId.digitalocean:
        return apiKey != null && apiKey.trim().isNotEmpty;
    }
  }

  Future<Map<String, VultrNodeRecord>> _loadNodeRecords() async {
    final records = await _loadNodeRecordsFor(_providerId);
    _nodeRecords = records;
    return records;
  }

  Future<Map<String, VultrNodeRecord>> _loadNodeRecordsFor(
      CloudProviderId providerId) async {
    await _initializeStorage();
    final storageKey = providerId.nodeRecordsStorageKey;
    var raw = await StorageService.getSecureString(storageKey);
    if (raw == null || raw.isEmpty) {
      final legacy = StorageService.getString(storageKey);
      if (legacy != null && legacy.isNotEmpty) {
        raw = legacy;
        final savedSecurely =
            await StorageService.saveSecureString(storageKey, legacy);
        if (savedSecurely) {
          await StorageService.remove(storageKey);
        }
      }
    }
    if (raw == null || raw.isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final output = <String, VultrNodeRecord>{};
        for (final entry in decoded.entries) {
          final id = entry.key.toString();
          if (entry.value is Map) {
            output[id] = VultrNodeRecord.fromJson(
                id, Map<String, dynamic>.from(entry.value as Map));
          }
        }
        return output;
      }
    } catch (e) {
      AppLogger.error(
          '[CloudProvider] Failed to parse local node records for ${providerId.id}',
          e);
    }
    return {};
  }

  Future<void> _saveNodeRecords() async {
    await _saveNodeRecordsFor(_providerId, _nodeRecords);
  }

  Future<void> _saveNodeRecordsFor(
    CloudProviderId providerId,
    Map<String, VultrNodeRecord> records,
  ) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    final payload = <String, dynamic>{};
    for (final item in records.entries) {
      payload[item.key] = item.value.toJson();
    }
    final savedSecurely = await StorageService.saveSecureString(
        providerId.nodeRecordsStorageKey, jsonEncode(payload));
    if (!savedSecurely) {
      // Node records hold per-node credentials. Secure storage is fail-closed,
      // so on keystore failure they stay only in memory and are gone after a
      // restart. Unlike the API key they are recoverable (a cloud refresh
      // re-fetches them), so this is a logged warning rather than a hard error.
      AppLogger.warning(
        '[CloudProvider] Node records could not be persisted to the keystore '
        '(${providerId.nodeRecordsStorageKey}); they will need a cloud refresh after restart.',
      );
    }
  }

  bool _isStaleProviderRequest(CloudProviderId providerId, int requestEpoch) {
    return _providerId != providerId || _providerRequestEpoch != requestEpoch;
  }

  Future<void> _updateNodeRecord(
    String instanceId,
    Map<String, dynamic> updates,
  ) async {
    final existing =
        _nodeRecords[instanceId] ?? VultrNodeRecord(instanceId: instanceId);
    _nodeRecords[instanceId] = existing.copyWithJson(updates);
    await _saveNodeRecords();
  }

  Future<void> refreshCloudConfig({bool notify = true}) async {
    final providerId = _providerId;
    final requestEpoch = _providerRequestEpoch;
    if (providerId == CloudProviderId.ssh) {
      _providerExtra = await _getStoredProviderExtraFor(providerId);
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _apiKey = null;
      _hasApiKey = hasValidSshAccessConfig(_providerExtra);
      _error = null;
      _configLoaded = true;
      if (notify && !_isStaleProviderRequest(providerId, requestEpoch)) {
        notifyListeners();
      }
      return;
    }
    try {
      final key = await _getStoredApiKeyFor(providerId);
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      if (key == null || key.isEmpty) {
        _hasApiKey = false;
        _configLoaded = true;
        _error = null;
        if (notify) {
          notifyListeners();
        }
        return;
      }

      final client = _buildClient(providerId, key);
      await client.validateApiKey();
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _apiKey = key;
      _hasApiKey = true;
      _error = null;
      _configLoaded = true;
    } catch (e) {
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _configLoaded = true;
      _error =
          'Failed to load cloud configuration: ${cloudProviderMessageFromError(e)}';
      // Only flip hasApiKey to false when we have no cached instances to fall
      // back on. A transient validation failure (API timeout, TLS hiccup)
      // shouldn't evict a stored key and usable cached nodes from the UI —
      // otherwise the Workspace shows a blocking "failed to load" card on top
      // of nodes that are fully connectable.
      _hasApiKey = _instances.isNotEmpty &&
          _apiKey != null &&
          _apiKey!.trim().isNotEmpty;
      AppLogger.error('[CloudProvider] Load cloud config error', e);
    }

    if (notify && !_isStaleProviderRequest(providerId, requestEpoch)) {
      notifyListeners();
    }
  }

  Future<bool> setApiKey(String key) async {
    if (key.trim().isEmpty) {
      _error = 'API key cannot be empty';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final normalizedKey = key.trim();
      if (!await _saveApiKey(normalizedKey)) {
        _error = 'Could not store the API key securely on this device. '
            'The device keystore is unavailable, so the key was not saved.';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final client = await _cloudClient();
      try {
        await client.validateApiKey();
      } catch (e) {
        // Save-first / verify-later: a transient network failure here
        // (timeout, DNS lookup failure, socket refused, certificate
        // hiccup) is the exact shape of what happens on the
        // China-Mobile cellular networks where this app is supposed to
        // help — the carrier blocks api.vultr.com (or api.do.com, etc)
        // outright, so the validation call can never complete from
        // cellular even with a perfectly-good token. Previously we
        // cleared the disk-saved key and returned false; the user saw
        // "Failed to save API key" and was completely stuck unless
        // they could find a Wi-Fi access point first. Now we keep the
        // saved key, surface the failure as an informational message,
        // and defer the actual validation + node-list refresh until
        // the next time the network can reach the provider.
        //
        // Auth failures (401/403/"invalid api key") still abort and
        // clear, because those mean the token itself is wrong and no
        // amount of waiting for the network will fix it.
        if (shouldKeepCloudApiKeyOnError(e)) {
          _error =
              'API key saved. Could not reach ${providerId.displayName} to verify yet '
              '(${cloudProviderMessageFromError(e)}) — we will retry when the '
              'network reaches it.';
          AppLogger.warning(
            '[CloudProvider] API key saved, online verify deferred: $e',
          );
          return true;
        }
        await _clearApiKey();
        _error = 'Failed to save API key: ${cloudProviderMessageFromError(e)}';
        AppLogger.error('[CloudProvider] Save API key error', e);
        return false;
      }

      await _loadNodeRecords();
      await refreshCloudConfig(notify: false);
      await loadRegions(notify: false);
      await loadPlans(notify: false);
      // Best-effort: probe the upstream account status so the UI can degrade
      // immediately after a valid key lands, instead of waiting for the first
      // deploy attempt. Failures are non-fatal — refreshAccountStatus stores
      // an unknown state and the deploy button stays enabled.
      unawaited(refreshAccountStatus());
      return true;
    } catch (e) {
      // Pre-validate failures (storage, normalization) — keep the
      // previous strict policy since they're not network-related.
      if (!shouldKeepCloudApiKeyOnError(e)) {
        await _clearApiKey();
      }
      _error = 'Failed to save API key: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Save API key error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> setSshAccessConfig({
    required String host,
    required String port,
    required String username,
    required String password,
  }) async {
    final normalized = normalizeSshAccessConfig(
      host: host,
      port: port,
      username: username,
      password: password,
    );
    if (!hasValidSshAccessConfig(normalized)) {
      _error = 'SSH host, username, and password are required';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await testSshConnection(normalized);
      if (!await _saveProviderExtra(normalized)) {
        _error = 'Could not store SSH credentials securely on this device. '
            'The device keystore is unavailable, so they were not saved.';
        return false;
      }
      _apiKey = null;
      _hasApiKey = true;
      _configLoaded = true;
      _error = null;
      return true;
    } catch (e) {
      _error = 'Failed to save SSH access: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Save SSH access error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadInstances({bool notify = true}) async {
    final providerId = _providerId;
    final requestEpoch = _providerRequestEpoch;
    if (!await _ensureAuthorizedCloudAccess(
      notify: notify,
      expectedProvider: providerId,
      requestEpoch: requestEpoch,
    )) {
      return;
    }
    if (_isStaleProviderRequest(providerId, requestEpoch)) {
      return;
    }

    _isLoading = true;
    _error = null;
    if (notify) {
      notifyListeners();
    }

    try {
      if (providerId == CloudProviderId.ssh) {
        final records = await _loadNodeRecordsFor(providerId);
        if (_isStaleProviderRequest(providerId, requestEpoch)) {
          return;
        }
        _nodeRecords = records;
        _instances = records.values
            .where((record) => record.instanceId.isNotEmpty)
            .map((record) => record.toCloudInstance())
            .toList()
          ..sort(
            (a, b) => (b.createdAt ?? DateTime(0))
                .compareTo(a.createdAt ?? DateTime(0)),
          );
        _error = null;
        AppLogger.info('[CloudProvider] Loaded ${_instances.length} SSH nodes');
        return;
      }

      final key = await _getStoredApiKeyFor(providerId);
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      if (key == null || key.isEmpty) {
        throw StateError('${providerId.displayName} API key is not configured');
      }
      final client = _buildClient(providerId, key);
      final data = await client.listInstances();
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      final rawInstances = (data['instances'] as List?) ?? const [];
      final knownRecords = await _loadNodeRecordsFor(providerId);
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _nodeRecords = knownRecords;
      var recordsChanged = false;
      final parsed = <CloudInstance>[];

      // Build source maps first, then recover missing records in parallel.
      final sources = <String, Map<String, dynamic>>{};
      for (final item in rawInstances.whereType<Map>()) {
        final source = Map<String, dynamic>.from(item);
        // The API clients don't inject a provider field, so stamp it here —
        // we know these rows came from the active provider's API. Without
        // this, CloudInstance.fromJson falls back to 'vultr' for everything.
        source['provider'] = providerId.id;
        final id = source['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          sources[id] = source;
        } else {
          parsed.add(CloudInstance.fromJson(source));
        }
      }

      final liveInstanceIds = sources.keys.toSet();
      final claimedReplacementIds = <String>{};
      for (final entry in sources.entries) {
        if (knownRecords.containsKey(entry.key)) {
          continue;
        }

        final source = entry.value;
        final replacementId = _findReplacementNodeRecordId(
          instanceId: entry.key,
          label: source['label']?.toString() ?? '',
          region: source['region']?.toString() ?? '',
          ipv4: source['main_ip']?.toString() ?? '',
          ipv6: source['v6_main_ip']?.toString() ?? '',
          knownRecords: knownRecords,
          liveInstanceIds: liveInstanceIds,
          claimedRecordIds: claimedReplacementIds,
        );
        if (replacementId == null) {
          continue;
        }

        final previous = knownRecords.remove(replacementId);
        if (previous == null) {
          continue;
        }

        claimedReplacementIds.add(replacementId);
        knownRecords[entry.key] = _prepareReplacementNodeRecord(
          record: previous,
          instanceId: entry.key,
          label: source['label']?.toString() ?? previous.label,
          region: source['region']?.toString() ?? previous.region,
          plan: source['plan']?.toString() ?? previous.plan,
          ipv4: source['main_ip']?.toString() ?? '',
          ipv6: source['v6_main_ip']?.toString() ?? '',
          createdAt: source['date_created']?.toString() ??
              source['created_at']?.toString() ??
              source['createdAt']?.toString() ??
              previous.createdAt,
        );
        recordsChanged = true;
        AppLogger.info(
          '[CloudProvider] Migrated replaced node record $replacementId -> ${entry.key}',
        );
      }

      // Kick off all recovery requests concurrently.
      final recoveryFutures = <String, Future<VultrNodeRecord?>>{};
      for (final entry in sources.entries) {
        final record = knownRecords[entry.key];
        if (_shouldRecoverNodeRecord(record)) {
          final s = entry.value;
          recoveryFutures[entry.key] = _recoverNodeRecordFromUserData(
            client: client,
            instanceId: entry.key,
            label: s['label']?.toString() ?? '',
            region: s['region']?.toString() ?? '',
            plan: s['plan']?.toString() ?? '',
            ipv4: s['main_ip']?.toString() ?? '',
            ipv6: s['v6_main_ip']?.toString() ?? '',
            createdAt: s['date_created']?.toString() ??
                s['created_at']?.toString() ??
                s['createdAt']?.toString() ??
                '',
            existing: record,
          );
        }
      }

      final recoveredResults = <String, VultrNodeRecord?>{};
      if (recoveryFutures.isNotEmpty) {
        final keys = recoveryFutures.keys.toList();
        final values = await Future.wait(recoveryFutures.values);
        if (_isStaleProviderRequest(providerId, requestEpoch)) {
          return;
        }
        for (var i = 0; i < keys.length; i++) {
          recoveredResults[keys[i]] = values[i];
        }
      }

      for (final entry in sources.entries) {
        final id = entry.key;
        final source = entry.value;
        var record = knownRecords[id];
        final recovered = recoveredResults[id];
        if (recovered != null) {
          record = recovered;
          knownRecords[id] = recovered;
          recordsChanged = true;
        }

        if (record == null) {
          parsed.add(CloudInstance.fromJson(source));
          continue;
        }

        final merged = Map<String, dynamic>.from(source)
          ..addAll(record.toMergeableJson());
        parsed.add(CloudInstance.fromJson(merged));
      }

      // The API call above succeeded, so any cached record NOT in the live
      // list is a node the provider confirmed is gone. Do NOT silently delete
      // it: surface it flagged so the user is prompted and only a confirm
      // removes it (see [missingInstances] / [purgeMissingInstance]). The
      // record is kept on disk until then so the flag survives across refreshes
      // and restarts; a transient API failure can't reach here (it throws into
      // the catch, leaving the cached records untouched).
      final staleIds = knownRecords.keys
          .where((id) => !liveInstanceIds.contains(id))
          .toSet();
      _missingInstances = knownRecords.values
          .where((record) =>
              record.instanceId.isNotEmpty &&
              staleIds.contains(record.instanceId))
          .map((record) => record.toCloudInstance().copyWith(missing: true))
          .toList();
      // Drop prompted-state for ids that have reappeared (e.g. repaired), so a
      // future deletion of the same id prompts again.
      _missingPrompted.removeWhere((id) => !staleIds.contains(id));
      if (_missingInstances.isNotEmpty) {
        AppLogger.info(
          '[CloudProvider] ${_missingInstances.length} cached node(s) confirmed deleted upstream — awaiting user removal',
        );
      }

      _instances = parsed;
      _instances.sort(
        (a, b) =>
            (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      _latencyChecks.removeWhere(
        (instanceId, _) =>
            !_instances.any((instance) => instance.id == instanceId),
      );

      for (final item in _instances) {
        if (item.id.isNotEmpty) {
          final record = knownRecords[item.id];
          if (record != null) {
            var updated = record.copyWithJson({
              'label': item.label,
              'region': item.region,
              'ipv4': item.ipv4 ?? record.ipv4,
              'ipv6': item.ipv6 ?? record.ipv6,
              'plan': item.plan,
              'createdAt':
                  item.createdAt?.toIso8601String() ?? record.createdAt,
            });
            // Self-heal: older builds never stamped the source provider, so
            // some records still claim provider=vultr despite being stored
            // under, e.g., the DigitalOcean namespace. We know the authoritative
            // provider here — correct it so the merged-view chip is accurate.
            if (updated.provider != providerId) {
              updated = VultrNodeRecord(
                instanceId: updated.instanceId,
                provider: providerId,
                label: updated.label,
                region: updated.region,
                plan: updated.plan,
                osId: updated.osId,
                ssPort: updated.ssPort,
                ssPassword: updated.ssPassword,
                hyPort: updated.hyPort,
                hyPassword: updated.hyPassword,
                hyServerName: updated.hyServerName,
                vlessPort: updated.vlessPort,
                vlessUuid: updated.vlessUuid,
                vlessPublicKey: updated.vlessPublicKey,
                vlessShortId: updated.vlessShortId,
                vlessServerName: updated.vlessServerName,
                trojanPort: updated.trojanPort,
                trojanPassword: updated.trojanPassword,
                trojanServerName: updated.trojanServerName,
                ipv4: updated.ipv4,
                ipv6: updated.ipv6,
                createdAt: updated.createdAt,
                portProfile: updated.portProfile,
                planRam: updated.planRam,
              );
            }
            if (updated.toJson().toString() != record.toJson().toString()) {
              knownRecords[item.id] = updated;
              recordsChanged = true;
            }
          } else {
            // Persist a minimal record (no credentials) for every cloud-
            // reported instance so the node stays visible in the merged
            // all-providers view after the user switches active provider.
            knownRecords[item.id] = VultrNodeRecord(
              instanceId: item.id,
              provider: providerId,
              label: item.label,
              region: item.region,
              plan: item.plan,
              ipv4: item.ipv4 ?? '',
              ipv6: item.ipv6 ?? '',
              createdAt: item.createdAt?.toIso8601String() ?? '',
            );
            recordsChanged = true;
          }
        }
      }

      if (recordsChanged) {
        _nodeRecords = knownRecords;
        await _saveNodeRecordsFor(providerId, knownRecords);
      }

      AppLogger.info('[CloudProvider] Loaded ${_instances.length} instances');
    } catch (e) {
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _error = 'Failed to load instances: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Load instances error', e);
    } finally {
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      // Refresh the merged-view cache for every non-active provider from its
      // persisted node records so the UI can show all providers' nodes at
      // once. This reads from local storage only (no API calls) — switching
      // active provider is still the way to force a live refresh for it.
      await _loadOtherProviderInstancesFromCache();
      if (_isStaleProviderRequest(providerId, requestEpoch)) {
        return;
      }
      _isLoading = false;
      if (notify) {
        notifyListeners();
      }
      _evaluatePendingPoll();
    }
  }

  bool _hasPendingInstances() {
    if (isSshProvider) {
      return false;
    }
    for (final inst in _instances) {
      if (!(inst.isActive && inst.hasIp && inst.nodeInfo != null)) {
        return true;
      }
    }
    return false;
  }

  void _evaluatePendingPoll() {
    if (_disposed) {
      _pendingPollTimer?.cancel();
      _pendingPollTimer = null;
      _pendingPollStartedAt = null;
      return;
    }
    final pending = _hasPendingInstances();
    if (!pending) {
      _pendingPollTimer?.cancel();
      _pendingPollTimer = null;
      _pendingPollStartedAt = null;
      return;
    }
    if (_pendingPollTimer != null) {
      return;
    }
    _pendingPollStartedAt = DateTime.now();
    _pendingPollTimer = Timer.periodic(_pendingPollInterval, (_) {
      if (_disposed) {
        _pendingPollTimer?.cancel();
        _pendingPollTimer = null;
        return;
      }
      final startedAt = _pendingPollStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > _pendingPollMaxDuration) {
        AppLogger.info(
            '[CloudProvider] Pending poll exceeded max duration; stopping');
        _pendingPollTimer?.cancel();
        _pendingPollTimer = null;
        _pendingPollStartedAt = null;
        return;
      }
      if (_isLoading) {
        return;
      }
      unawaited(loadInstances());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingPollTimer?.cancel();
    _pendingPollTimer = null;
    _pendingPollStartedAt = null;
    super.dispose();
  }

  Future<void> _loadOtherProviderInstancesFromCache() async {
    _otherProviderInstances.clear();
    for (final pid in CloudProviderId.values) {
      if (pid == _providerId) continue;
      final records = await _loadNodeRecordsFor(pid);
      if (records.isEmpty) continue;
      // Show every record with a non-empty id, not just ones with full SS
      // credentials. DigitalOcean records often lack recovered credentials
      // (DO doesn't expose user-data) but are still useful to list so the
      // user can see, delete, or refresh them.
      final list = records.values
          .where((r) => r.instanceId.isNotEmpty)
          .map((record) => record.toCloudInstance())
          .toList();
      if (list.isNotEmpty) {
        _otherProviderInstances[pid] = list;
      }
    }
  }

  bool _shouldRecoverNodeRecord(VultrNodeRecord? record) {
    if (record == null || record.ssPort <= 0 || record.ssPassword.isEmpty) {
      return true;
    }
    // Re-run recovery when vlessRelayPort is missing: nodes created before
    // the M1 install script (or before the ufw-limit regex fix) saved
    // records with vlessRelayPort=0, which disables the CDN deploy button
    // even when the node actually has a working relay listener. One extra
    // user-data fetch per refresh is cheap; it overwrites with the same
    // record for genuinely legacy nodes and unblocks M1 nodes the first
    // time the regex matches.
    return record.vlessRelayPort <= 0;
  }

  Future<VultrNodeRecord?> _recoverNodeRecordFromUserData({
    required CloudApiClient client,
    required String instanceId,
    required String label,
    required String region,
    required String plan,
    required String ipv4,
    required String ipv6,
    required String createdAt,
    required VultrNodeRecord? existing,
  }) async {
    try {
      final userData = await client.getInstanceUserData(instanceId);
      if (userData == null || userData.trim().isEmpty) {
        return null;
      }

      final recovered = recoverVultrNodeRecordFromUserData(userData);
      if (recovered == null || !recovered.isUsable) {
        return null;
      }

      final base = existing ?? VultrNodeRecord(instanceId: instanceId);
      return base.copyWithJson({
        ...recovered.toNodeRecordJson(),
        'instanceId': instanceId,
        'label': label,
        'region': region,
        'plan': plan,
        'ipv4': ipv4,
        'ipv6': ipv6,
        'createdAt': createdAt,
      });
    } catch (e) {
      AppLogger.warning(
        '[CloudProvider] Failed to recover node credentials for $instanceId: ${e.toString()}',
      );
      return null;
    }
  }

  Future<void> loadRegions({bool notify = true}) async {
    if (_providerId == CloudProviderId.ssh) {
      _regions = const [];
      _error = null;
      if (notify) {
        notifyListeners();
      }
      return;
    }
    if (_regionsLoadFuture != null) {
      return _regionsLoadFuture!;
    }

    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

    final completer = Completer<void>();
    _regionsLoadFuture = completer.future;
    _isLoadingRegions = true;
    if (notify) {
      notifyListeners();
    }

    () async {
      try {
        final client = await _cloudClient();
        final data = await client.listRegions();
        final rawRegions = (data['regions'] as List?) ?? const [];
        _regions = rawRegions
            .whereType<Map>()
            .map(
                (item) => CloudRegion.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        _error = null;
      } catch (e) {
        _error = 'Failed to load regions: ${cloudProviderMessageFromError(e)}';
        AppLogger.error('[CloudProvider] Load regions error', e);
      } finally {
        _isLoadingRegions = false;
        _regionsLoadFuture = null;
        if (notify) {
          notifyListeners();
        }
        completer.complete();
      }
    }();

    return completer.future;
  }

  /// Whether per-region reachability probes are currently in flight.
  bool get isProbingRegions => _isProbingRegions;

  /// Latest reachability/latency result for a region code, or null if not yet
  /// probed. `isTesting` while in flight; `error != null` (or null latencyMs)
  /// means unreachable from the current network.
  CloudLatencyCheck? regionLatencyFor(String regionId) =>
      _regionLatencyChecks[regionId];

  /// Probe reachability + latency to every loaded region that has a known Vultr
  /// anchor IP, from the device's current network, so the deploy dialog can
  /// steer the user away from regions their network is blocking. Vultr-only
  /// (the anchor table is provider-specific); a no-op for DigitalOcean/SSH.
  /// Results cache for [latencyCacheMaxAge]; pass [force] to re-probe sooner.
  Future<void> probeRegionLatencies({bool force = false}) async {
    if (_providerId != CloudProviderId.vultr || _isProbingRegions) {
      return;
    }
    final now = DateTime.now();
    final pending = _regions.where((region) {
      if (!vultrRegionHasLatencyAnchor(region.id)) {
        return false;
      }
      if (force) {
        return true;
      }
      final cached = _regionLatencyChecks[region.id];
      if (cached == null) {
        return true;
      }
      if (cached.isTesting) {
        return false;
      }
      final updatedAt = cached.updatedAt;
      return updatedAt == null ||
          now.difference(updatedAt) >= latencyCacheMaxAge;
    }).toList();
    if (pending.isEmpty) {
      return;
    }

    _isProbingRegions = true;
    for (final region in pending) {
      // Keep any prior result visible while re-probing. The dropdown menu is a
      // frozen snapshot once open, so flipping an already-measured region back
      // to a spinner would strand it spinning until the user closes/reopens.
      // Only never-probed regions show the testing state.
      _regionLatencyChecks.putIfAbsent(
        region.id,
        () => CloudLatencyCheck.testing(updatedAt: now),
      );
    }
    notifyListeners();

    await Future.wait(
      pending.map((region) async {
        final latencyMs = await _regionLatencyProbe(region.id);
        if (_disposed) {
          return;
        }
        _regionLatencyChecks[region.id] = latencyMs == null
            ? CloudLatencyCheck.failure(
                error: 'unreachable',
                updatedAt: DateTime.now(),
              )
            : CloudLatencyCheck.success(
                latencyMs: latencyMs,
                updatedAt: DateTime.now(),
              );
      }),
    );

    if (_disposed) {
      return;
    }
    _isProbingRegions = false;
    unawaited(_persistRegionLatencies());
    notifyListeners();
  }

  /// The loaded region with the lowest measured latency that is currently
  /// reachable, or null if none have been confirmed reachable yet. Used by the
  /// deploy dialog to pre-select the best region.
  String? fastestReachableRegionId() {
    String? bestId;
    int? bestMs;
    for (final region in _regions) {
      final check = _regionLatencyChecks[region.id];
      final ms = check?.latencyMs;
      if (check == null ||
          check.isTesting ||
          check.error != null ||
          ms == null) {
        continue;
      }
      if (bestMs == null || ms < bestMs) {
        bestMs = ms;
        bestId = region.id;
      }
    }
    return bestId;
  }

  Future<void> loadPlans({bool notify = true}) async {
    if (_providerId == CloudProviderId.ssh) {
      _plans = const [];
      _error = null;
      if (notify) {
        notifyListeners();
      }
      return;
    }
    if (_plansLoadFuture != null) {
      return _plansLoadFuture!;
    }

    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

    final completer = Completer<void>();
    _plansLoadFuture = completer.future;
    _isLoadingPlans = true;
    if (notify) {
      notifyListeners();
    }

    () async {
      try {
        final client = await _cloudClient();
        final data = await client.listPlans();
        final rawPlans = (data['plans'] as List?) ?? const [];
        _plans = rawPlans
            .whereType<Map>()
            .map((item) => CloudPlan.fromJson(Map<String, dynamic>.from(item)))
            .where((plan) => plan.monthlyCost <= 24 && plan.monthlyCost > 0)
            .toList()
          ..sort((a, b) => a.monthlyCost.compareTo(b.monthlyCost));
        _error = null;
      } catch (e) {
        _error = 'Failed to load plans: ${cloudProviderMessageFromError(e)}';
        AppLogger.error('[CloudProvider] Load plans error', e);
      } finally {
        _isLoadingPlans = false;
        _plansLoadFuture = null;
        if (notify) {
          notifyListeners();
        }
        completer.complete();
      }
    }();

    return completer.future;
  }

  Future<CloudLatencyCheck> testInstanceLatency(
    CloudInstance instance, {
    CloudProbeMode mode = CloudProbeMode.quick,
  }) async {
    final previous = _latencyChecks[instance.id];
    final testing = CloudLatencyCheck.testing(
      updatedAt: DateTime.now(),
      mode: mode,
    );
    _latencyChecks[instance.id] = testing;
    notifyListeners();

    final probe = mode == CloudProbeMode.benchmark
        ? _benchmarkLatencyProbe
        : _latencyProbe;
    final result = await probe(instance);
    _latencyChecks[instance.id] = mode == CloudProbeMode.quick &&
            previous != null &&
            previous.hasThroughput &&
            !result.hasThroughput
        ? previous.copyWith(
            latencyMs: result.latencyMs,
            endpointLabel: result.endpointLabel,
            error: result.error,
            updatedAt: result.updatedAt,
          )
        : result;
    notifyListeners();
    return _latencyChecks[instance.id]!;
  }

  void saveLatencyCheck(
    String instanceId,
    CloudLatencyCheck check, {
    bool notify = true,
  }) {
    _latencyChecks[instanceId] = check;
    if (notify) {
      notifyListeners();
    }
  }

  Future<CloudFastestNodeSelection> selectFastestConnectableInstance({
    bool forceRefresh = false,
    Duration maxAge = latencyCacheMaxAge,
  }) async {
    final candidates = _connectableCandidates();
    if (candidates.isEmpty) {
      return const CloudFastestNodeSelection(
        error: 'No ready cloud nodes are available yet',
      );
    }

    final now = DateTime.now();
    final nodesToRefresh = forceRefresh
        ? candidates
        : candidates
            .where(
                (instance) => !_hasFreshLatencyCheck(instance.id, now, maxAge))
            .toList(growable: false);

    if (nodesToRefresh.isNotEmpty) {
      await Future.wait(nodesToRefresh.map(testInstanceLatency));
    }

    return _selectionFromLatencyChecks(
      candidates,
      usedCachedResults: nodesToRefresh.isEmpty,
    );
  }

  CloudFastestNodeSelection cachedFastestConnectableInstance({
    Duration maxAge = latencyCacheMaxAge,
  }) {
    return _selectionFromLatencyChecks(
      _connectableCandidates(),
      maxAge: maxAge,
      usedCachedResults: true,
    );
  }

  Future<CloudFastestNodeSelection> benchmarkConnectableInstances() async {
    final candidates = _connectableCandidates();
    if (candidates.isEmpty) {
      return const CloudFastestNodeSelection(
        error: 'No ready cloud nodes are available yet',
      );
    }

    await Future.wait(
      candidates.map(
        (instance) => testInstanceLatency(
          instance,
          mode: CloudProbeMode.benchmark,
        ),
      ),
    );

    return _selectionFromLatencyChecks(
      candidates,
      usedCachedResults: false,
    );
  }

  bool _hasFreshLatencyCheck(
    String instanceId,
    DateTime now,
    Duration maxAge,
  ) {
    final check = _latencyChecks[instanceId];
    final updatedAt = check?.updatedAt;
    if (check == null || check.isTesting || updatedAt == null) {
      return false;
    }
    return now.difference(updatedAt) <= maxAge;
  }

  List<CloudInstance> _connectableCandidates() {
    return _instances
        .where(
          (instance) =>
              instance.isActive && instance.hasIp && instance.nodeInfo != null,
        )
        .toList(growable: false);
  }

  CloudFastestNodeSelection _selectionFromLatencyChecks(
    List<CloudInstance> candidates, {
    Duration? maxAge,
    required bool usedCachedResults,
  }) {
    final now = DateTime.now();
    CloudInstance? fastestInstance;
    CloudLatencyCheck? fastestCheck;
    var successCount = 0;
    String? lastError;

    for (final instance in candidates) {
      final check = _latencyChecks[instance.id];
      if (check == null || check.isTesting) {
        continue;
      }
      if (maxAge != null) {
        final updatedAt = check.updatedAt;
        if (updatedAt == null || now.difference(updatedAt) > maxAge) {
          continue;
        }
      }
      if (check.latencyMs != null) {
        successCount += 1;
        if (fastestCheck == null || _isBetterSelection(check, fastestCheck)) {
          fastestInstance = instance;
          fastestCheck = check;
        }
      } else if (check.error != null && check.error!.trim().isNotEmpty) {
        lastError = check.error;
      }
    }

    if (fastestInstance == null || fastestCheck == null) {
      return CloudFastestNodeSelection(
        testedCount: candidates.length,
        successCount: successCount,
        usedCachedResults: usedCachedResults,
        error: lastError ?? 'Latency testing did not return a usable node',
      );
    }

    return CloudFastestNodeSelection(
      instance: fastestInstance,
      latencyCheck: fastestCheck,
      testedCount: candidates.length,
      successCount: successCount,
      usedCachedResults: usedCachedResults,
    );
  }

  bool _isBetterSelection(
    CloudLatencyCheck candidate,
    CloudLatencyCheck incumbent,
  ) {
    final candidateThroughput = candidate.throughputMbps;
    final incumbentThroughput = incumbent.throughputMbps;
    if (candidateThroughput != null || incumbentThroughput != null) {
      if (candidateThroughput == null) {
        return false;
      }
      if (incumbentThroughput == null) {
        return true;
      }

      if ((candidateThroughput - incumbentThroughput).abs() >= 0.01) {
        return candidateThroughput > incumbentThroughput;
      }
    }

    return _latencySelectionScore(candidate) <
        _latencySelectionScore(incumbent);
  }

  int _latencySelectionScore(CloudLatencyCheck check) {
    final latencyMs = check.latencyMs ?? (1 << 30);
    final sampleCount = check.sampleCount ?? 1;
    final successfulSamples = check.successfulSamples ?? 1;
    final failedSamples =
        sampleCount > successfulSamples ? sampleCount - successfulSamples : 0;
    final reliabilityPenalty = failedSamples * (check.isBenchmark ? 250 : 400);
    return latencyMs + reliabilityPenalty;
  }

  // Populated by the most recent successful [createInstance] call so the
  // caller can chain follow-up actions (e.g. deploy a CDN worker) without
  // having to rediscover the new node via label matching. Cleared at the
  // start of each call. Not part of the bool return because that would
  // ripple through every mock CloudProvider in tests.
  String? _lastCreatedInstanceId;
  String? get lastCreatedInstanceId => _lastCreatedInstanceId;

  Future<bool> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    return _createInstance(
      region: region,
      plan: plan,
      label: label,
      validateSelection: true,
    );
  }

  Future<bool> _createInstance({
    required String region,
    required String plan,
    required String label,
    required bool validateSelection,
  }) async {
    if (!await _ensureAuthorizedCloudAccess()) {
      return false;
    }

    _isLoading = true;
    _error = null;
    _lastCreatedInstanceId = null;
    notifyListeners();

    try {
      if (_providerId == CloudProviderId.ssh) {
        final resolvedLabel = normalizeInstanceLabel(label);
        final deployment = await deployNodeViaSsh(
          extra: _providerExtra,
          label: resolvedLabel,
        );
        await _updateNodeRecord(
          deployment.record.instanceId,
          deployment.record.toJson(),
        );
        await _loadNodeRecords();
        await loadInstances(notify: false);
        _lastCreatedInstanceId = deployment.record.instanceId;
        return true;
      }

      final resolvedLabel = normalizeInstanceLabel(label);
      if (validateSelection) {
        final selectionError = validateDeploymentSelection(
          region: region,
          plan: plan,
          regions: _regions,
          plans: _plans,
        );
        if (selectionError != null) {
          _error = selectionError;
          return false;
        }
      }

      final client = await _cloudClient();
      final planInfo = await client.getPlanById(plan);
      final planRam =
          cloudJsonIntValue(planInfo, const ['ram', 'memory', 'memory_mb']);
      final deployment = await VultrDeploymentBuilder.build(
        planRam: planRam,
        portProfile: _selectedProfile,
      );

      final osIds = preferredCloudOsIds(await client.getOperatingSystems());
      if (osIds.isEmpty) {
        throw StateError('No supported OS image found in Vultr account');
      }
      Map<String, dynamic>? instancePayload;
      StateError? lastError;

      for (final osId in osIds) {
        try {
          final response = await client.createInstance(
            region: region,
            plan: plan,
            label: resolvedLabel,
            osId: osId,
            userData: deployment.userData,
          );
          final raw = response['instance'] ?? response;
          if (raw is Map<String, dynamic>) {
            instancePayload = Map<String, dynamic>.from(raw);
          }
          if (instancePayload != null) {
            break;
          }
        } catch (e) {
          if (e is StateError) {
            lastError = e;
            continue;
          }
          rethrow;
        }
      }

      if (instancePayload == null) {
        throw lastError ?? StateError('Failed to create instance');
      }

      final instanceId = instancePayload['id']?.toString();
      if (instanceId == null || instanceId.isEmpty) {
        throw StateError('Invalid instance response: missing instance id');
      }

      final createdAt = instancePayload['created_at']?.toString() ??
          instancePayload['createdAt']?.toString() ??
          DateTime.now().toUtc().toIso8601String();

      await _updateNodeRecord(instanceId, {
        ...deployment.nodeRecord,
        'plan': plan,
        'region': region,
        'label': resolvedLabel,
        'osId': osIds.first,
        'createdAt': createdAt,
        'ipv4': instancePayload['main_ip'] ?? '',
        'ipv6': instancePayload['v6_main_ip'] ?? '',
        'instanceId': instanceId,
      });
      await _loadNodeRecords();
      await loadInstances(notify: false);
      _lastCreatedInstanceId = instanceId;
      return true;
    } catch (e) {
      _error = 'Failed to create instance: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Create instance error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> repairInstance(String id) async {
    final instance = _findInstanceById(id);
    if (instance == null) {
      _error = 'Failed to repair instance: node not found';
      notifyListeners();
      return false;
    }

    final owner = _findInstanceOwner(id) ??
        CloudProviderId.tryParse(instance.provider) ??
        _providerId;
    if (owner != _providerId) {
      _error = 'Switch to ${owner.displayName} to repair this node';
      notifyListeners();
      return false;
    }

    if (owner == CloudProviderId.ssh) {
      return _repairSshInstance(instance);
    }

    return _createInstance(
      region: instance.region,
      plan: instance.plan,
      label: redeployInstanceLabel(instance.label),
      validateSelection: false,
    );
  }

  Future<bool> _repairSshInstance(CloudInstance instance) async {
    if (!await _ensureAuthorizedCloudAccess()) {
      return false;
    }

    _isLoading = true;
    _error = null;
    _lastCreatedInstanceId = null;
    notifyListeners();

    try {
      final deployment = await deployNodeViaSsh(
        extra: _providerExtra,
        label: normalizeInstanceLabel(instance.label),
      );
      final repairedJson = deployment.record.toJson()
        ..['provider'] = CloudProviderId.ssh.id
        ..['label'] = instance.label
        ..['region'] = instance.region.isNotEmpty
            ? instance.region
            : deployment.record.region
        ..['plan'] =
            instance.plan.isNotEmpty ? instance.plan : deployment.record.plan
        ..['ipv4'] = instance.ipv4 ?? deployment.record.ipv4
        ..['ipv6'] = instance.ipv6 ?? deployment.record.ipv6
        ..['createdAt'] = instance.createdAt?.toUtc().toIso8601String() ??
            deployment.record.createdAt;

      _nodeRecords[instance.id] = VultrNodeRecord.fromJson(
        instance.id,
        repairedJson,
      );
      await _saveNodeRecords();
      await _loadNodeRecords();
      await loadInstances(notify: false);
      return true;
    } catch (e) {
      _error = 'Failed to repair instance: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Repair SSH node error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteInstance(String id) async {
    // Find the instance in the merged view so we can route the delete call
    // to whichever provider actually owns it, even if it's not the active
    // provider. Falls back to the active provider's client for unknown ids.
    final owner = _findInstanceOwner(id);

    if (owner == CloudProviderId.ssh) {
      _isLoading = true;
      _error = null;
      notifyListeners();
      try {
        final records = await _loadNodeRecordsFor(CloudProviderId.ssh);
        records.remove(id);
        await _saveNodeRecordsFor(CloudProviderId.ssh, records);
        if (_providerId == CloudProviderId.ssh) {
          _nodeRecords = records;
          _instances = records.values
              .where((record) => record.instanceId.isNotEmpty)
              .map((record) => record.toCloudInstance())
              .toList()
            ..sort(
              (a, b) => (b.createdAt ?? DateTime(0))
                  .compareTo(a.createdAt ?? DateTime(0)),
            );
        } else {
          final list = _otherProviderInstances[CloudProviderId.ssh];
          if (list != null) {
            _otherProviderInstances[CloudProviderId.ssh] =
                list.where((instance) => instance.id != id).toList();
          }
        }
        _latencyChecks.remove(id);
        await _removePreferredEndpointLabelForInstance(CloudProviderId.ssh, id);
        return true;
      } catch (e) {
        _error =
            'Failed to delete instance: ${cloudProviderMessageFromError(e)}';
        AppLogger.error('[CloudProvider] Delete SSH node error', e);
        return false;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    if (owner == null || owner == _providerId) {
      if (!await _ensureAuthorizedCloudAccess()) {
        return false;
      }
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final client = owner != null && owner != _providerId
          ? await _clientForProvider(owner)
          : await _cloudClient();
      if (client == null) {
        _error = 'Failed to delete instance: API key not configured for '
            '${owner?.displayName ?? 'provider'}';
        return false;
      }
      await client.deleteInstance(id);
      if (owner == null || owner == _providerId) {
        _nodeRecords.remove(id);
        _latencyChecks.remove(id);
        await _removePreferredEndpointLabelForInstance(_providerId, id);
        await _saveNodeRecords();
        _instances = _instances.where((instance) => instance.id != id).toList();
      } else {
        // Prune the instance from the other-provider cache and its on-disk
        // records so the merged view updates immediately.
        final list = _otherProviderInstances[owner];
        if (list != null) {
          _otherProviderInstances[owner] =
              list.where((instance) => instance.id != id).toList();
        }
        await _removeNodeRecordFor(owner, id);
        _latencyChecks.remove(id);
        await _removePreferredEndpointLabelForInstance(owner, id);
      }
      return true;
    } catch (e) {
      _error = 'Failed to delete instance: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Delete instance error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Remove a node the provider API already confirmed is gone. This only
  /// clears the local cached record/labels — it deliberately does NOT call the
  /// provider delete API (the instance no longer exists upstream). Returns
  /// false for an id that isn't a tracked confirmed-missing node.
  Future<bool> purgeMissingInstance(String id) async {
    final instance =
        _missingInstances.where((node) => node.id == id).firstOrNull;
    if (instance == null) {
      return false;
    }
    final owner = CloudProviderId.tryParse(instance.provider) ?? _providerId;
    try {
      await _removeNodeRecordFor(owner, id);
      if (owner == _providerId) {
        _nodeRecords.remove(id);
      }
      _latencyChecks.remove(id);
      await _removePreferredEndpointLabelForInstance(owner, id);
      _missingInstances =
          _missingInstances.where((node) => node.id != id).toList();
      _missingPrompted.remove(id);
      _instances = _instances.where((node) => node.id != id).toList();
      final cached = _otherProviderInstances[owner];
      if (cached != null) {
        _otherProviderInstances[owner] =
            cached.where((node) => node.id != id).toList();
      }
      AppLogger.info('[CloudProvider] Purged confirmed-deleted node $id');
      return true;
    } catch (e) {
      _error =
          'Failed to remove deleted node: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Purge missing node error', e);
      return false;
    } finally {
      notifyListeners();
    }
  }

  CloudProviderId? _findInstanceOwner(String id) {
    if (_instances.any((i) => i.id == id)) return _providerId;
    for (final entry in _otherProviderInstances.entries) {
      if (entry.value.any((i) => i.id == id)) return entry.key;
    }
    return null;
  }

  CloudInstance? _findInstanceById(String id) {
    final active = _instances.where((i) => i.id == id).firstOrNull;
    if (active != null) return active;
    for (final list in _otherProviderInstances.values) {
      final found = list.where((i) => i.id == id).firstOrNull;
      if (found != null) return found;
    }
    return null;
  }

  Future<void> _removePreferredEndpointLabelForInstance(
    CloudProviderId providerId,
    String instanceId,
  ) async {
    final removed =
        _preferredEndpointLabels.remove('${providerId.id}:$instanceId');
    if (removed != null) {
      await _persistPreferredEndpointLabels();
    }
  }

  Future<void> _clearPreferredEndpointLabelsForProvider(
    CloudProviderId providerId,
  ) async {
    _preferredEndpointLabels.removeWhere(
      (key, _) => key.startsWith('${providerId.id}:'),
    );
    await _persistPreferredEndpointLabels();
  }

  Future<void> _removeNodeRecordFor(
      CloudProviderId providerId, String instanceId) async {
    final records = await _loadNodeRecordsFor(providerId);
    if (!records.containsKey(instanceId)) return;
    records.remove(instanceId);
    final payload = <String, dynamic>{};
    for (final item in records.entries) {
      payload[item.key] = item.value.toJson();
    }
    await StorageService.saveSecureString(
        providerId.nodeRecordsStorageKey, jsonEncode(payload));
  }

  void reset() {
    _instances = [];
    _regions = [];
    _plans = [];
    _hasApiKey = false;
    _configLoaded = false;
    _apiKey = null;
    _providerExtra = {};
    _error = null;
    _nodeRecords = {};
    notifyListeners();
  }

  Future<void> clearLocalCloudData() async {
    await _clearApiKey();
    await _clearProviderExtra();
    _nodeRecords = {};
    await _clearPreferredEndpointLabelsForProvider(_providerId);
    await StorageService.removeSecure(nodeRecordsStorageKey);
    await StorageService.remove(nodeRecordsStorageKey);
    reset();
  }

  Future<String> exportBackupJson() async {
    final key = await _getStoredApiKey();
    final extra = await _getStoredProviderExtra();
    final records = await _loadNodeRecords();
    final payload = <String, dynamic>{};
    for (final entry in records.entries) {
      payload[entry.key] = entry.value.toJson();
    }
    return createCloudBackupJson(
      provider: providerName,
      apiKey: key,
      extra: extra.isEmpty ? null : extra,
      nodeRecords: payload,
    );
  }

  Future<void> importBackupJson(String raw) async {
    final backup = parseCloudBackupJson(
      raw,
      expectedProvider: providerName,
    );

    if (backup.apiKey != null && backup.apiKey!.isNotEmpty) {
      if (!await _saveApiKey(backup.apiKey!)) {
        throw StateError(
          'Could not store the restored API key securely (device keystore unavailable).',
        );
      }
    } else {
      await _clearApiKey();
    }

    if (backup.extra != null && backup.extra!.isNotEmpty) {
      if (!await _saveProviderExtra(backup.extra!)) {
        throw StateError(
          'Could not store the restored provider credentials securely (device keystore unavailable).',
        );
      }
    } else {
      await _clearProviderExtra();
    }

    final importedRecords = <String, VultrNodeRecord>{};
    for (final entry in backup.nodeRecords.entries) {
      importedRecords[entry.key] = VultrNodeRecord.fromJson(
        entry.key,
        entry.value,
      );
    }

    _nodeRecords = importedRecords;
    await _saveNodeRecords();
    _instances = importedRecords.values
        .map((record) => record.toCloudInstance())
        .toList()
      ..sort(
        (a, b) =>
            (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
    _regions = [];
    _plans = [];
    _error = null;
    _configLoaded = false;
    _hasApiKey = _hasStoredAccessFor(_providerId, _apiKey, _providerExtra);
    notifyListeners();

    unawaited(
      _refreshImportedBackupCloudState(_providerId, _providerRequestEpoch),
    );
  }

  /// Optional callback the App injects so that node configs include a
  /// CDN-fronted variant when the user has set one up. Returns the
  /// hostname AND the per-deployment PATH_SECRET as a [CdnEndpoint] —
  /// preferring the M1 Workers Custom Domain (e.g.
  /// `relay-9f2c8a.example.com`) when bound, falling back to the
  /// `*.workers.dev` host. Returns null when the node has no Worker
  /// deployed.
  CdnEndpoint? Function(String nodeId)? _cdnEndpointResolver;

  void setCdnEndpointResolver(CdnEndpoint? Function(String nodeId)? resolver) {
    _cdnEndpointResolver = resolver;
  }

  String? generateNodeConfig(CloudInstance instance) {
    // Pull in every other usable cloud node as a failover. sing-box urltest
    // then probes them all and picks whichever is reachable from the
    // current underlying network. The user-facing intent: when their
    // carrier blackholes one VPS IP on cellular, another node still works
    // without manual intervention.
    final failovers = _instances
        .where(
          (candidate) =>
              candidate.id != instance.id &&
              candidate.hasIp &&
              candidate.nodeInfo != null,
        )
        .toList(growable: false);

    return buildCloudNodeConfig(
      instance,
      preferredEndpointLabel: preferredEndpointLabelFor(instance),
      targetPlatform: defaultTargetPlatform,
      cdnEndpoint: _cdnEndpointResolver?.call(instance.id),
      failoverInstances: failovers,
      failoverCdnEndpointResolver: _cdnEndpointResolver == null
          ? null
          : (failover) => _cdnEndpointResolver?.call(failover.id),
    );
  }

  Future<bool> _ensureAuthorizedCloudAccess({
    bool notify = true,
    CloudProviderId? expectedProvider,
    int? requestEpoch,
  }) async {
    final providerId = expectedProvider ?? _providerId;
    final epoch = requestEpoch ?? _providerRequestEpoch;
    if (_isStaleProviderRequest(providerId, epoch)) {
      return false;
    }
    if (!_configLoaded) {
      await refreshCloudConfig(notify: false);
    }
    if (_isStaleProviderRequest(providerId, epoch)) {
      return false;
    }

    if (!_hasApiKey) {
      // Keep the last validation/loading error visible when a key is still
      // stored locally but cloud authorization is currently failing.
      if (!hasStoredApiKey) {
        _error = null;
      }
      if (notify) {
        notifyListeners();
      }
      return false;
    }

    return true;
  }

  Future<void> _refreshImportedBackupCloudState(
    CloudProviderId importedProvider,
    int requestEpoch,
  ) async {
    if (_isStaleProviderRequest(importedProvider, requestEpoch)) {
      return;
    }
    await refreshCloudConfig(notify: false);
    if (_isStaleProviderRequest(importedProvider, requestEpoch)) {
      return;
    }
    if (_hasApiKey) {
      await loadInstances(notify: false);
    }
    if (_isStaleProviderRequest(importedProvider, requestEpoch)) {
      return;
    }
    notifyListeners();
  }
}

String? _findReplacementNodeRecordId({
  required String instanceId,
  required String label,
  required String region,
  required String ipv4,
  required String ipv6,
  required Map<String, VultrNodeRecord> knownRecords,
  required Set<String> liveInstanceIds,
  required Set<String> claimedRecordIds,
}) {
  final addressMatches = <String>[];
  final labelRegionMatches = <String>[];

  final normalizedLabel = label.trim().toLowerCase();
  final normalizedRegion = region.trim().toLowerCase();
  final normalizedIpv4 = ipv4.trim();
  final normalizedIpv6 = ipv6.trim().toLowerCase();

  for (final entry in knownRecords.entries) {
    if (entry.key == instanceId ||
        liveInstanceIds.contains(entry.key) ||
        claimedRecordIds.contains(entry.key)) {
      continue;
    }

    final record = entry.value;
    final recordIpv4 = record.ipv4.trim();
    final recordIpv6 = record.ipv6.trim().toLowerCase();
    if ((normalizedIpv4.isNotEmpty && recordIpv4 == normalizedIpv4) ||
        (normalizedIpv6.isNotEmpty &&
            recordIpv6.isNotEmpty &&
            recordIpv6 == normalizedIpv6)) {
      addressMatches.add(entry.key);
      continue;
    }

    final recordLabel = record.label.trim().toLowerCase();
    final recordRegion = record.region.trim().toLowerCase();
    if (normalizedLabel.isNotEmpty &&
        normalizedRegion.isNotEmpty &&
        recordLabel == normalizedLabel &&
        recordRegion == normalizedRegion) {
      labelRegionMatches.add(entry.key);
    }
  }

  if (addressMatches.length == 1) {
    return addressMatches.first;
  }
  if (labelRegionMatches.length == 1) {
    return labelRegionMatches.first;
  }
  return null;
}

VultrNodeRecord _prepareReplacementNodeRecord({
  required VultrNodeRecord record,
  required String instanceId,
  required String label,
  required String region,
  required String plan,
  required String ipv4,
  required String ipv6,
  required String createdAt,
}) {
  final next = record.toJson()
    ..['label'] = label
    ..['region'] = region
    ..['plan'] = plan
    ..['ipv4'] = ipv4
    ..['ipv6'] = ipv6
    ..['createdAt'] = createdAt
    ..['ssPort'] = 0
    ..['ssPassword'] = ''
    ..['hyPort'] = 0
    ..['hyPassword'] = ''
    ..['hysteriaServerName'] = ''
    ..['vlessPort'] = 0
    ..['vlessUUID'] = ''
    ..['vlessPublicKey'] = ''
    ..['vlessShortId'] = ''
    ..['vlessServerName'] = ''
    ..['trojanPort'] = 0
    ..['trojanPassword'] = ''
    ..['trojanServerName'] = '';

  return VultrNodeRecord.fromJson(instanceId, next);
}

Future<CloudLatencyCheck> _defaultLatencyProbe(CloudInstance instance) async {
  return _probeCloudInstanceLatency(
    instance,
    mode: CloudProbeMode.quick,
  );
}

Future<CloudLatencyCheck> _defaultBenchmarkLatencyProbe(
  CloudInstance instance,
) async {
  return _probeCloudInstanceLatency(
    instance,
    mode: CloudProbeMode.benchmark,
  );
}

Future<CloudLatencyCheck> _probeCloudInstanceLatency(
  CloudInstance instance, {
  required CloudProbeMode mode,
}) async {
  final host = (() {
    final ipv4 = instance.ipv4?.trim();
    if (ipv4 != null && ipv4.isNotEmpty && ipv4 != '0.0.0.0') {
      return ipv4;
    }
    final ipv6 = instance.ipv6?.trim();
    if (ipv6 != null && ipv6.isNotEmpty) {
      return ipv6;
    }
    return null;
  })();
  final nodeInfo = instance.nodeInfo;
  if (!instance.isActive || host == null || host.isEmpty || nodeInfo == null) {
    return CloudLatencyCheck.failure(
      error: 'Node is not ready for latency testing yet',
      updatedAt: DateTime.now(),
      mode: mode,
    );
  }

  final targets = <({String label, int port})>[];
  void addTarget(String label, int port) {
    if (port <= 0) {
      return;
    }
    targets.add((label: label, port: port));
  }

  final supportedLabels = supportedCloudProbeEndpointsForCurrentPlatform(
    nodeInfo: nodeInfo,
  );
  if (supportedLabels.contains('Trojan')) {
    addTarget('Trojan', nodeInfo.trojanPort);
  }
  if (supportedLabels.contains('VLESS')) {
    addTarget('VLESS', nodeInfo.vlessPort);
  }
  if (supportedLabels.contains('Shadowsocks')) {
    addTarget('Shadowsocks', nodeInfo.ssPort);
  }

  if (targets.isEmpty) {
    final hasAnyPort = nodeInfo.ssPort > 0 ||
        nodeInfo.trojanPort > 0 ||
        nodeInfo.vlessPort > 0 ||
        nodeInfo.hyPort > 0;
    return CloudLatencyCheck.failure(
      error: hasAnyPort
          ? 'No TCP endpoint is available for testing'
          : '节点凭证已丢失(可能因重装应用)。请销毁后重建,或从备份恢复。',
      updatedAt: DateTime.now(),
      mode: mode,
    );
  }

  final targetResults = await Future.wait(
    targets.map(
      (target) => mode == CloudProbeMode.benchmark
          ? _runBenchmarkEndpointProbe(
              host: host,
              label: target.label,
              port: target.port,
            )
          : _runQuickEndpointProbe(
              host: host,
              label: target.label,
              port: target.port,
            ),
    ),
  );

  final successfulResults = targetResults
      .where((result) => result.latencyMs != null && result.scoreMs != null)
      .toList(growable: false)
    ..sort((a, b) => a.scoreMs!.compareTo(b.scoreMs!));
  final lastError = targetResults
      .map((result) => result.error)
      .whereType<String>()
      .where((error) => error.trim().isNotEmpty)
      .firstOrNull;

  if (successfulResults.isNotEmpty) {
    final fastest = successfulResults.first;
    return CloudLatencyCheck.success(
      latencyMs: fastest.latencyMs!,
      endpointLabel: fastest.label,
      updatedAt: DateTime.now(),
      mode: mode,
      sampleCount: fastest.sampleCount,
      successfulSamples: fastest.successfulSamples,
    );
  }

  return CloudLatencyCheck.failure(
    error: lastError ??
        (mode == CloudProbeMode.benchmark
            ? 'Benchmark test failed'
            : 'Latency test failed'),
    updatedAt: DateTime.now(),
    mode: mode,
  );
}

@visibleForTesting
List<String> supportedCloudProbeEndpointsForCurrentPlatform({
  required NodeInfo nodeInfo,
  TargetPlatform? targetPlatform,
}) {
  final _ = targetPlatform ?? defaultTargetPlatform;
  final labels = <String>[];
  // Intentionally do NOT require passwords/UUIDs here: the latency probe
  // below is a plain TCP Socket.connect measurement, not a protocol
  // handshake, so reachability is meaningful even when creds are empty in
  // the local record. This matters for DigitalOcean droplets — DO doesn't
  // expose user-data, so the app can't always recover every protocol's
  // secrets, leaving populated ports with empty passwords. Without this,
  // DO nodes show "No TCP endpoint is available for testing" even though
  // the ports are open and listening.
  if (nodeInfo.trojanPort > 0) {
    labels.add('Trojan');
  }
  // Keep the quick/benchmark selector on TCP-capable protocols only. Hy2 is
  // now allowed on Android, but this helper still measures reachability via
  // TCP Socket.connect, so it cannot rank a UDP-only protocol correctly.
  if (nodeInfo.vlessPort > 0) {
    labels.add('VLESS');
  }
  if (nodeInfo.ssPort > 0) {
    labels.add('Shadowsocks');
  }
  return labels;
}

Future<_CloudEndpointProbeResult> _runQuickEndpointProbe({
  required String host,
  required String label,
  required int port,
}) async {
  final latencyMs = await _probeTcpLatency(
    host: host,
    port: port,
    timeout: CloudProvider.quickProbeTimeout,
  );
  if (latencyMs == null) {
    return _CloudEndpointProbeResult(
      label: label,
      sampleCount: 1,
      successfulSamples: 0,
      error: '$label port $port unavailable',
    );
  }

  return _CloudEndpointProbeResult(
    label: label,
    latencyMs: latencyMs,
    sampleCount: 1,
    successfulSamples: 1,
    scoreMs: latencyMs,
  );
}

Future<_CloudEndpointProbeResult> _runBenchmarkEndpointProbe({
  required String host,
  required String label,
  required int port,
}) async {
  final samples = <int>[];
  for (var index = 0;
      index < CloudProvider.benchmarkProbeSamplesPerEndpoint;
      index += 1) {
    final latencyMs = await _probeTcpLatency(
      host: host,
      port: port,
      timeout: CloudProvider.benchmarkProbeTimeout,
    );
    if (latencyMs != null) {
      samples.add(latencyMs);
    }
  }

  if (samples.isEmpty) {
    return _CloudEndpointProbeResult(
      label: label,
      sampleCount: CloudProvider.benchmarkProbeSamplesPerEndpoint,
      successfulSamples: 0,
      error: '$label port $port did not answer benchmark probes',
    );
  }

  samples.sort();
  final medianLatencyMs = samples[samples.length ~/ 2];
  final failedSamples =
      CloudProvider.benchmarkProbeSamplesPerEndpoint - samples.length;
  return _CloudEndpointProbeResult(
    label: label,
    latencyMs: medianLatencyMs,
    sampleCount: CloudProvider.benchmarkProbeSamplesPerEndpoint,
    successfulSamples: samples.length,
    scoreMs: medianLatencyMs + (failedSamples * 250),
  );
}

Future<int?> _probeTcpLatency({
  required String host,
  required int port,
  required Duration timeout,
}) async {
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: timeout,
    );
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds.clamp(1, 9999).toInt();
  } catch (_) {
    stopwatch.stop();
    return null;
  } finally {
    socket?.destroy();
  }
}

class _CloudEndpointProbeResult {
  const _CloudEndpointProbeResult({
    required this.label,
    required this.sampleCount,
    required this.successfulSamples,
    this.latencyMs,
    this.scoreMs,
    this.error,
  });

  final String label;
  final int sampleCount;
  final int successfulSamples;
  final int? latencyMs;
  final int? scoreMs;
  final String? error;
}
