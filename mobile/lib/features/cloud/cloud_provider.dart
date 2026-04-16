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
import 'vultr_deploy.dart';
import 'vultr_client.dart';
import 'vultr_user_data_recovery.dart';

typedef CloudLatencyProbe = Future<CloudLatencyCheck> Function(
    CloudInstance instance);

class CloudProvider extends CloudProviderBase {
  CloudProviderId _providerId = CloudProviderId.vultr;

  @override
  CloudProviderId get providerId => _providerId;

  static const String _activeProviderStorageKey = 'mobile_cloud_active_provider';
  static const Duration latencyCacheMaxAge = Duration(minutes: 5);
  static const Duration connectSelectionReuseMaxAge = Duration(minutes: 30);
  static const Duration quickProbeTimeout = Duration(milliseconds: 900);
  static const Duration benchmarkProbeTimeout = Duration(milliseconds: 1500);
  static const int benchmarkProbeSamplesPerEndpoint = 3;

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
  final String _selectedProfile = PortProfileAllocator.randomProfile;
  Map<String, VultrNodeRecord> _nodeRecords = {};
  final Map<String, CloudLatencyCheck> _latencyChecks = {};
  Future<void>? _regionsLoadFuture;
  Future<void>? _plansLoadFuture;
  final CloudLatencyProbe _latencyProbe;
  final CloudLatencyProbe _benchmarkLatencyProbe;
  bool _benchmarkAllRunning = false;
  bool _benchmarkAbortRequested = false;
  // Cached CloudInstance lists for providers OTHER than the active one, so
  // the UI can show all nodes from every configured provider in one list.
  // Populated by loadInstances alongside the active provider's live fetch.
  final Map<CloudProviderId, List<CloudInstance>> _otherProviderInstances = {};

  List<CloudInstance> get instances => _instances;

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
    final list = merged.values.toList()
      ..sort((a, b) => (b.createdAt ?? DateTime(0))
          .compareTo(a.createdAt ?? DateTime(0)));
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
  bool get hasStoredApiKey => _apiKey?.trim().isNotEmpty == true;
  bool get isConfigured => _hasApiKey && _configLoaded;
  CloudLatencyCheck? latencyCheckFor(String instanceId) =>
      _latencyChecks[instanceId];

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
    bool autoInitialize = true,
  })  : _latencyProbe = latencyProbe ?? _defaultLatencyProbe,
        _benchmarkLatencyProbe =
            benchmarkLatencyProbe ?? _defaultBenchmarkLatencyProbe {
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
    _hasApiKey = _apiKey != null && _apiKey!.isNotEmpty;
    _configLoaded = true;
    notifyListeners();
  }

  Future<void> _restorePersistedActiveProvider() async {
    final stored = StorageService.getString(_activeProviderStorageKey);
    final parsed = CloudProviderId.tryParse(stored);
    if (parsed != null) {
      _providerId = parsed;
    }
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
    _providerId = target;
    await StorageService.saveString(_activeProviderStorageKey, target.id);

    // Reset in-memory state tied to the previous provider. Disk records
    // remain under the old provider's storage keys and will rehydrate when
    // the user switches back.
    _instances = const [];
    _regions = const [];
    _plans = const [];
    _nodeRecords = {};
    _latencyChecks.clear();
    _apiKey = null;
    _hasApiKey = false;
    _error = null;

    await _loadNodeRecords();
    _restoreInstancesFromCache();
    await _loadOtherProviderInstancesFromCache();
    _apiKey = await _getStoredApiKey();
    _hasApiKey = _apiKey != null && _apiKey!.isNotEmpty;
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
    }
  }

  Future<CloudApiClient?> _clientForProvider(CloudProviderId id) async {
    final key = await StorageService.getSecureString(id.apiKeyStorageKey) ??
        StorageService.getString(id.apiKeyStorageKey);
    if (key == null || key.isEmpty) return null;
    return _buildClient(id, key);
  }

  Future<String?> _getStoredApiKey() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = await StorageService.getSecureString(apiKeyStorageKey);
    if (_apiKey == null || _apiKey!.isEmpty) {
      final legacy = StorageService.getString(apiKeyStorageKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        _apiKey = legacy.trim();
        await StorageService.saveSecureString(apiKeyStorageKey, _apiKey!);
        await StorageService.remove(apiKeyStorageKey);
      }
    }
    return _apiKey?.trim();
  }

  // Persist a new key and mark cloud access as available. Keep these flags
  // in sync inside the helper so callers (importBackupJson, setApiKey, etc.)
  // cannot drift — historically importBackupJson called _saveApiKey but
  // forgot to set _hasApiKey, leaving Workspace stuck on the empty state
  // until the app was restarted.
  Future<void> _saveApiKey(String key) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = key.trim();
    _hasApiKey = _apiKey!.isNotEmpty;
    await StorageService.saveSecureString(apiKeyStorageKey, _apiKey!);
    await StorageService.remove(apiKeyStorageKey);
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
        await StorageService.saveSecureString(storageKey, legacy);
        await StorageService.remove(storageKey);
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
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    final payload = <String, dynamic>{};
    for (final item in _nodeRecords.entries) {
      payload[item.key] = item.value.toJson();
    }
    await StorageService.saveSecureString(
        nodeRecordsStorageKey, jsonEncode(payload));
    await StorageService.remove(nodeRecordsStorageKey);
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
    try {
      final key = await _getStoredApiKey();
      if (key == null || key.isEmpty) {
        _hasApiKey = false;
        _configLoaded = true;
        _error = null;
        if (notify) {
          notifyListeners();
        }
        return;
      }

      final client = await _cloudClient();
      await client.validateApiKey();
      _hasApiKey = true;
      _error = null;
      _configLoaded = true;
    } catch (e) {
      _hasApiKey = false;
      _configLoaded = true;
      _error =
          'Failed to load cloud configuration: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Load cloud config error', e);
    }

    if (notify) {
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
      await _saveApiKey(normalizedKey);

      final client = await _cloudClient();
      await client.validateApiKey();

      await _loadNodeRecords();
      await refreshCloudConfig(notify: false);
      await loadRegions(notify: false);
      await loadPlans(notify: false);
      return true;
    } catch (e) {
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

  Future<void> loadInstances({bool notify = true}) async {
    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

    _isLoading = true;
    _error = null;
    if (notify) {
      notifyListeners();
    }

    try {
      final client = await _cloudClient();
      final data = await client.listInstances();
      final rawInstances = (data['instances'] as List?) ?? const [];
      final knownRecords = await _loadNodeRecords();
      var recordsChanged = false;
      final parsed = <CloudInstance>[];

      // Build source maps first, then recover missing records in parallel.
      final sources = <String, Map<String, dynamic>>{};
      for (final item in rawInstances.whereType<Map>()) {
        final source = Map<String, dynamic>.from(item);
        // The API clients don't inject a provider field, so stamp it here —
        // we know these rows came from the active provider's API. Without
        // this, CloudInstance.fromJson falls back to 'vultr' for everything.
        source['provider'] = _providerId.id;
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

      final apiReturnedInstances = liveInstanceIds.isNotEmpty;
      if (parsed.isEmpty && knownRecords.isNotEmpty) {
        parsed.addAll(knownRecords.values
            .where((r) => r.instanceId.isNotEmpty)
            .map((record) => record.toCloudInstance()));
      } else if (apiReturnedInstances) {
        // Prune records for instances deleted on the cloud side. We only do
        // this when the API returned a non-empty list to avoid wiping local
        // records on a transient empty response.
        final stale = knownRecords.keys
            .where((id) => !liveInstanceIds.contains(id))
            .toList();
        if (stale.isNotEmpty) {
          for (final id in stale) {
            knownRecords.remove(id);
          }
          recordsChanged = true;
          AppLogger.info(
            '[CloudProvider] Pruned ${stale.length} local record(s) for instances no longer on cloud',
          );
        }
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
            if (updated.provider != _providerId) {
              updated = VultrNodeRecord(
                instanceId: updated.instanceId,
                provider: _providerId,
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
              provider: _providerId,
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
        await _saveNodeRecords();
      }

      AppLogger.info('[CloudProvider] Loaded ${_instances.length} instances');
    } catch (e) {
      _error = 'Failed to load instances: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Load instances error', e);
    } finally {
      // Refresh the merged-view cache for every non-active provider from its
      // persisted node records so the UI can show all providers' nodes at
      // once. This reads from local storage only (no API calls) — switching
      // active provider is still the way to force a live refresh for it.
      await _loadOtherProviderInstancesFromCache();
      _isLoading = false;
      if (notify) {
        notifyListeners();
      }
    }
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
    return record == null || record.ssPort <= 0 || record.ssPassword.isEmpty;
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

  Future<void> loadPlans({bool notify = true}) async {
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

  Future<bool> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    if (!await _ensureAuthorizedCloudAccess()) {
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final resolvedLabel = normalizeInstanceLabel(label);
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

  Future<bool> deleteInstance(String id) async {
    // Find the instance in the merged view so we can route the delete call
    // to whichever provider actually owns it, even if it's not the active
    // provider. Falls back to the active provider's client for unknown ids.
    final owner = _findInstanceOwner(id);

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
        await _saveNodeRecords();
        _instances =
            _instances.where((instance) => instance.id != id).toList();
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

  CloudProviderId? _findInstanceOwner(String id) {
    if (_instances.any((i) => i.id == id)) return _providerId;
    for (final entry in _otherProviderInstances.entries) {
      if (entry.value.any((i) => i.id == id)) return entry.key;
    }
    return null;
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
    _error = null;
    _nodeRecords = {};
    notifyListeners();
  }

  Future<void> clearLocalCloudData() async {
    await _clearApiKey();
    _nodeRecords = {};
    await StorageService.removeSecure(nodeRecordsStorageKey);
    await StorageService.remove(nodeRecordsStorageKey);
    reset();
  }

  Future<String> exportBackupJson() async {
    final key = await _getStoredApiKey();
    final records = await _loadNodeRecords();
    final payload = <String, dynamic>{};
    for (final entry in records.entries) {
      payload[entry.key] = entry.value.toJson();
    }
    return createCloudBackupJson(
      provider: providerName,
      apiKey: key,
      nodeRecords: payload,
    );
  }

  Future<void> importBackupJson(String raw) async {
    final backup = parseCloudBackupJson(
      raw,
      expectedProvider: providerName,
    );

    if (backup.apiKey != null && backup.apiKey!.isNotEmpty) {
      await _saveApiKey(backup.apiKey!);
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
    notifyListeners();

    unawaited(_refreshImportedBackupCloudState());
  }

  String? generateNodeConfig(CloudInstance instance) {
    return buildCloudNodeConfig(
      instance,
      preferredEndpointLabel: _latencyChecks[instance.id]?.endpointLabel,
    );
  }

  Future<bool> _ensureAuthorizedCloudAccess({bool notify = true}) async {
    if (!_configLoaded) {
      await refreshCloudConfig(notify: false);
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

  Future<void> _refreshImportedBackupCloudState() async {
    await refreshCloudConfig(notify: false);
    if (_hasApiKey) {
      await loadInstances(notify: false);
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
    return CloudLatencyCheck.failure(
      error: 'No TCP endpoint is available for testing',
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
  final platform = targetPlatform ?? defaultTargetPlatform;
  final labels = <String>[];
  if (nodeInfo.trojanPort > 0 && nodeInfo.trojanPassword.isNotEmpty) {
    labels.add('Trojan');
  }
  final supportsVless =
      platform != TargetPlatform.android || !_androidBuildStripsVless();
  if (supportsVless &&
      nodeInfo.vlessPort > 0 &&
      nodeInfo.vlessUuid.isNotEmpty &&
      nodeInfo.vlessPublicKey.isNotEmpty &&
      nodeInfo.vlessShortId.isNotEmpty) {
    labels.add('VLESS');
  }
  if (nodeInfo.ssPort > 0 && nodeInfo.ssPassword.isNotEmpty) {
    labels.add('Shadowsocks');
  }
  return labels;
}

bool _androidBuildStripsVless() => true;

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
