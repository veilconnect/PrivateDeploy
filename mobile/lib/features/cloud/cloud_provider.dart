import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../shared/utils/logger.dart';
import '../../core/storage/storage_service.dart';
import 'cloud_backup.dart';
import 'cloud_node_config_builder.dart';
import 'cloud_node_record.dart';
import 'cloud_models.dart';
import 'cloud_provider_utils.dart';
import 'cloud_provider_validation.dart';
import 'vultr_deploy.dart';
import 'vultr_client.dart';
import 'vultr_user_data_recovery.dart';

class CloudProvider with ChangeNotifier {
  static const _providerName = 'vultr';
  static const String _apiKeyStorageKey = 'mobile_cloud_vultr_api_key';
  static const String _nodeRecordsStorageKey = 'mobile_cloud_vultr_nodes';

  List<CloudInstance> _instances = [];
  List<CloudRegion> _regions = [];
  List<CloudPlan> _plans = [];
  bool _isLoading = false;
  bool _configLoaded = false;
  bool _hasApiKey = false;
  String? _error;
  String? _apiKey;
  final String _selectedProfile = PortProfileAllocator.randomProfile;
  Map<String, VultrNodeRecord> _nodeRecords = {};

  List<CloudInstance> get instances => _instances;
  List<CloudRegion> get regions => _regions;
  List<CloudPlan> get plans => _plans;
  bool get isLoading => _isLoading;
  bool get configLoaded => _configLoaded;
  String? get error => _error;
  bool get hasApiKey => _hasApiKey;
  String? get apiKey => _apiKey;
  bool get isConfigured => _hasApiKey && _configLoaded;
  String get providerName => _providerName;

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

  CloudProvider() {
    _init();
  }

  Future<void> _init() async {
    await _initializeStorage();
    await refreshCloudConfig(notify: false);
    await _loadNodeRecords();
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

      for (final item in rawInstances.whereType<Map>()) {
        final source = Map<String, dynamic>.from(item);
        final id = source['id']?.toString() ?? '';
        var record = id.isNotEmpty ? knownRecords[id] : null;
        if (id.isNotEmpty && _shouldRecoverNodeRecord(record)) {
          final recovered = await _recoverNodeRecordFromUserData(
            client: client,
            instanceId: id,
            label: source['label']?.toString() ?? '',
            region: source['region']?.toString() ?? '',
            plan: source['plan']?.toString() ?? '',
            ipv4: source['main_ip']?.toString() ?? '',
            ipv6: source['v6_main_ip']?.toString() ?? '',
            createdAt: source['date_created']?.toString() ??
                source['created_at']?.toString() ??
                source['createdAt']?.toString() ??
                '',
            existing: record,
          );
          if (recovered != null) {
            record = recovered;
            knownRecords[id] = recovered;
            recordsChanged = true;
          }
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
    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

    try {
      final client = await _cloudClient();
      final data = await client.listRegions();
      final rawRegions = (data['regions'] as List?) ?? const [];
      _regions = rawRegions
          .whereType<Map>()
          .map((item) => CloudRegion.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      _error = null;
    } catch (e) {
      _error = 'Failed to load regions: ${cloudProviderMessageFromError(e)}';
      AppLogger.error('[CloudProvider] Load regions error', e);
    }

    if (notify) {
      notifyListeners();
    }
  }

  Future<void> loadPlans({bool notify = true}) async {
    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

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
    }

    if (notify) {
      notifyListeners();
    }
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
      if (entry.value is! Map) {
        throw FormatException(
          'Backup node record "${entry.key}" is not a JSON object',
        );
      }
      importedRecords[entry.key] = VultrNodeRecord.fromJson(
        entry.key,
        Map<String, dynamic>.from(entry.value as Map),
      );
    }

    _nodeRecords = importedRecords;
    await _saveNodeRecords();
    _instances = [];
    _regions = [];
    _plans = [];
    _error = null;
    _configLoaded = false;
    await refreshCloudConfig(notify: false);
    if (_hasApiKey) {
      await loadRegions(notify: false);
      await loadPlans(notify: false);
      await loadInstances(notify: false);
    } else if (importedRecords.isNotEmpty) {
      _instances = importedRecords.values
          .map((record) => record.toCloudInstance())
          .toList()
        ..sort(
          (a, b) => (b.createdAt ?? DateTime(0))
              .compareTo(a.createdAt ?? DateTime(0)),
        );
    }
    notifyListeners();
  }

  String? generateNodeConfig(CloudInstance instance) {
    return buildCloudNodeConfig(instance);
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
}
