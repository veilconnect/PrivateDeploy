import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../shared/utils/logger.dart';
import '../../core/storage/storage_service.dart';
import '../profiles/profile_provider.dart';
import 'cloud_backup.dart';
import 'cloud_node_config_builder.dart';
import 'cloud_node_record.dart';
import 'cloud_models.dart';
import 'cloud_provider_utils.dart';
import 'cloud_provider_validation.dart';
import 'vultr_deploy.dart';
import 'vultr_client.dart';
import 'vultr_user_data_recovery.dart';

typedef CloudLatencyProbe = Future<CloudLatencyCheck> Function(
    CloudInstance instance);

class CloudProvider with ChangeNotifier {
  static const _providerName = 'vultr';
  static const String _apiKeyStorageKey = 'mobile_cloud_vultr_api_key';
  static const String _nodeRecordsStorageKey = 'mobile_cloud_vultr_nodes';
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

  List<CloudInstance> get instances => _instances;
  List<CloudRegion> get regions => _regions;
  List<CloudPlan> get plans => _plans;
  bool get isLoading => _isLoading;
  bool get configLoaded => _configLoaded;
  bool get isLoadingRegions => _isLoadingRegions;
  bool get isLoadingPlans => _isLoadingPlans;
  String? get error => _error;
  bool get hasApiKey => _hasApiKey;
  String? get apiKey => _apiKey;
  bool get isConfigured => _hasApiKey && _configLoaded;
  String get providerName => _providerName;
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
    await _loadNodeRecords();
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

  Future<void> _initializeStorage() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
  }

  Future<VultrCloudClient> _cloudClient() async {
    final key = await _getStoredApiKey();
    if (key == null || key.isEmpty) {
      throw StateError('Vultr API key is not configured');
    }
    return VultrCloudClient(key);
  }

  Future<String?> _getStoredApiKey() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = await StorageService.getSecureString(_apiKeyStorageKey);
    if (_apiKey == null || _apiKey!.isEmpty) {
      final legacy = StorageService.getString(_apiKeyStorageKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        _apiKey = legacy.trim();
        await StorageService.saveSecureString(_apiKeyStorageKey, _apiKey!);
        await StorageService.remove(_apiKeyStorageKey);
      }
    }
    return _apiKey?.trim();
  }

  Future<void> _saveApiKey(String key) async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = key.trim();
    await StorageService.saveSecureString(_apiKeyStorageKey, _apiKey!);
    await StorageService.remove(_apiKeyStorageKey);
  }

  Future<void> _clearApiKey() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    _apiKey = null;
    await StorageService.removeSecure(_apiKeyStorageKey);
    await StorageService.remove(_apiKeyStorageKey);
  }

  Future<Map<String, VultrNodeRecord>> _loadNodeRecords() async {
    await _initializeStorage();
    var raw = await StorageService.getSecureString(_nodeRecordsStorageKey);
    if (raw == null || raw.isEmpty) {
      final legacy = StorageService.getString(_nodeRecordsStorageKey);
      if (legacy != null && legacy.isNotEmpty) {
        raw = legacy;
        await StorageService.saveSecureString(_nodeRecordsStorageKey, legacy);
        await StorageService.remove(_nodeRecordsStorageKey);
      }
    }
    if (raw == null || raw.isEmpty) {
      _nodeRecords = {};
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
        _nodeRecords = output;
        return output;
      }
    } catch (e) {
      AppLogger.error('[CloudProvider] Failed to parse local node records', e);
    }

    _nodeRecords = {};
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
        _nodeRecordsStorageKey, jsonEncode(payload));
    await StorageService.remove(_nodeRecordsStorageKey);
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
        final id = source['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          sources[id] = source;
        } else {
          parsed.add(CloudInstance.fromJson(source));
        }
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

      if (parsed.isEmpty && knownRecords.isNotEmpty) {
        parsed.addAll(knownRecords.values
            .where((r) => r.instanceId.isNotEmpty)
            .map((record) => record.toCloudInstance()));
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
            final updated = record.copyWithJson({
              'label': item.label,
              'region': item.region,
              'ipv4': item.ipv4 ?? record.ipv4,
              'ipv6': item.ipv6 ?? record.ipv6,
              'plan': item.plan,
              'createdAt':
                  item.createdAt?.toIso8601String() ?? record.createdAt,
            });
            if (updated.toJson().toString() != record.toJson().toString()) {
              knownRecords[item.id] = updated;
              recordsChanged = true;
            }
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
      _isLoading = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  bool _shouldRecoverNodeRecord(VultrNodeRecord? record) {
    return record == null || record.ssPort <= 0 || record.ssPassword.isEmpty;
  }

  Future<VultrNodeRecord?> _recoverNodeRecordFromUserData({
    required VultrCloudClient client,
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
    if (!await _ensureAuthorizedCloudAccess()) {
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final client = await _cloudClient();
      await client.deleteInstance(id);
      _nodeRecords.remove(id);
      _latencyChecks.remove(id);
      await _saveNodeRecords();
      _instances = _instances.where((instance) => instance.id != id).toList();
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
    await StorageService.removeSecure(_nodeRecordsStorageKey);
    await StorageService.remove(_nodeRecordsStorageKey);
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
      provider: _providerName,
      apiKey: key,
      nodeRecords: payload,
    );
  }

  Future<void> importBackupJson(String raw) async {
    final backup = parseCloudBackupJson(
      raw,
      expectedProvider: _providerName,
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
      _error = null;
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
