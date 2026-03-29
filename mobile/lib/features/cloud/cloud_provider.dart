import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../shared/utils/logger.dart';
import '../../core/storage/storage_service.dart';
import 'cloud_backup.dart';
import 'cloud_models.dart';
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
  Map<String, _VultrNodeRecord> _nodeRecords = {};

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
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }

    final ts = (now ?? DateTime.now().toUtc());
    String two(int value) => value.toString().padLeft(2, '0');
    final compact =
        '${ts.year.toString().substring(2)}${two(ts.month)}${two(ts.day)}'
        '${two(ts.hour)}${two(ts.minute)}${two(ts.second)}';
    return 'node-$compact';
  }

  @visibleForTesting
  static String? validateDeploymentSelection({
    required String region,
    required String plan,
    required List<CloudRegion> regions,
    required List<CloudPlan> plans,
  }) {
    final regionExists = regions.any((candidate) => candidate.id == region);
    if (!regionExists) {
      return 'Selected region is unavailable';
    }

    final selectedPlan =
        plans.where((candidate) => candidate.id == plan).firstOrNull;
    if (selectedPlan == null) {
      return 'Selected plan is unavailable';
    }
    if (!selectedPlan.locations.contains(region)) {
      return 'Selected plan is not available in the chosen region';
    }
    return null;
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

  Future<Map<String, _VultrNodeRecord>> _loadNodeRecords() async {
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
        final output = <String, _VultrNodeRecord>{};
        for (final entry in decoded.entries) {
          final id = entry.key.toString();
          if (entry.value is Map) {
            output[id] = _VultrNodeRecord.fromJson(
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
        _nodeRecords[instanceId] ?? _VultrNodeRecord(instanceId: instanceId);
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
      _error = 'Failed to load cloud configuration: ${_messageFromError(e)}';
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
      if (!_shouldKeepApiKeyOnError(e)) {
        await _clearApiKey();
      }
      _error = 'Failed to save API key: ${_messageFromError(e)}';
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
              'createdAt': item.createdAt?.toIso8601String() ?? record.createdAt,
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
      _error = 'Failed to load instances: ${_messageFromError(e)}';
      AppLogger.error('[CloudProvider] Load instances error', e);
    } finally {
      _isLoading = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  bool _shouldRecoverNodeRecord(_VultrNodeRecord? record) {
    return record == null || record.ssPort <= 0 || record.ssPassword.isEmpty;
  }

  Future<_VultrNodeRecord?> _recoverNodeRecordFromUserData({
    required VultrCloudClient client,
    required String instanceId,
    required String label,
    required String region,
    required String plan,
    required String ipv4,
    required String ipv6,
    required String createdAt,
    required _VultrNodeRecord? existing,
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

      final base = existing ?? _VultrNodeRecord(instanceId: instanceId);
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
      _error = 'Failed to load regions: ${_messageFromError(e)}';
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
      _error = 'Failed to load plans: ${_messageFromError(e)}';
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
      final planRam = _intValue(planInfo, const ['ram', 'memory', 'memory_mb']);
      final deployment = await VultrDeploymentBuilder.build(
        planRam: planRam,
        portProfile: _selectedProfile,
      );

      final osIds = await _preferredOsIds(client);
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
      _error = 'Failed to create instance: ${_messageFromError(e)}';
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
      _error = 'Failed to delete instance: ${_messageFromError(e)}';
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

    final importedRecords = <String, _VultrNodeRecord>{};
    for (final entry in backup.nodeRecords.entries) {
      if (entry.value is! Map) {
        throw FormatException(
          'Backup node record "${entry.key}" is not a JSON object',
        );
      }
      importedRecords[entry.key] = _VultrNodeRecord.fromJson(
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
    if (!instance.hasIp || instance.nodeInfo == null) {
      return null;
    }

    final ip = instance.ipv4!;
    final info = instance.nodeInfo!;
    final label = instance.label;
    final outbounds = <Map<String, dynamic>>[];
    final tags = <String>[];

    if (info.ssPort > 0 && info.ssPassword.isNotEmpty) {
      final tag = '$label-SS';
      outbounds.add({
        'type': 'shadowsocks',
        'tag': tag,
        'server': ip,
        'server_port': info.ssPort,
        'method': 'aes-256-gcm',
        'password': info.ssPassword,
      });
      tags.add(tag);
    }

    if (info.hyPort > 0 && info.hyPassword.isNotEmpty) {
      final tag = '$label-Hy2';
      outbounds.add({
        'type': 'hysteria2',
        'tag': tag,
        'server': ip,
        'server_port': info.hyPort,
        'up_mbps': 100,
        'down_mbps': 100,
        'password': info.hyPassword,
        'tls': {
          'enabled': true,
          'server_name': info.hyServerName.isNotEmpty ? info.hyServerName : ip,
          'insecure': info.hyInsecure ?? true,
        },
      });
      tags.add(tag);
    }

    if (info.vlessPort > 0 &&
        info.vlessUuid.isNotEmpty &&
        info.vlessPublicKey.isNotEmpty &&
        info.vlessShortId.isNotEmpty) {
      final tag = '$label-VLESS';
      final publicKeyUrlSafe = info.vlessPublicKey
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll(RegExp(r'=+$'), '');

      outbounds.add({
        'type': 'vless',
        'tag': tag,
        'server': ip,
        'server_port': info.vlessPort,
        'uuid': info.vlessUuid,
        'flow': 'xtls-rprx-vision',
        'tls': {
          'enabled': true,
          'server_name': info.vlessServerName.isNotEmpty
              ? info.vlessServerName
              : 'www.microsoft.com',
          'utls': {
            'enabled': true,
            'fingerprint': 'chrome',
          },
          'reality': {
            'enabled': true,
            'public_key': publicKeyUrlSafe,
            'short_id': info.vlessShortId,
          },
        },
      });
      tags.add(tag);
    }

    if (info.trojanPort > 0 && info.trojanPassword.isNotEmpty) {
      final tag = '$label-Trojan';
      outbounds.add({
        'type': 'trojan',
        'tag': tag,
        'server': ip,
        'server_port': info.trojanPort,
        'password': info.trojanPassword,
        'tls': {
          'enabled': true,
          'server_name':
              info.trojanServerName.isNotEmpty ? info.trojanServerName : ip,
          'insecure': info.trojanInsecure ?? true,
        },
      });
      tags.add(tag);
    }

    if (outbounds.isEmpty) {
      return null;
    }

    final config = {
      'log': {'level': 'info'},
      'dns': {
        'servers': [
          {
            'tag': 'dns-remote',
            'address': 'https://8.8.8.8/dns-query',
            'detour': 'select'
          },
          {'tag': 'dns-local', 'address': 'local'},
        ],
        'rules': [
          {
            'outbound': ['any'],
            'server': 'dns-local'
          },
        ],
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'tun0',
          'inet4_address': '172.19.0.1/30',
          'auto_route': true,
          'strict_route': true,
          'stack': 'system',
          'sniff': true,
        },
      ],
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': ['auto', ...tags],
          'default': 'auto',
        },
        {
          'type': 'urltest',
          'tag': 'auto',
          'outbounds': tags,
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '5m',
        },
        ...outbounds,
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'dns', 'tag': 'dns-out'},
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {
        'rules': [
          {'protocol': 'dns', 'outbound': 'dns-out'},
          {
            'geoip': ['private'],
            'outbound': 'direct'
          },
        ],
        'auto_detect_interface': true,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
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

  Future<List<int>> _preferredOsIds(VultrCloudClient client) async {
    final osData = await client.getOperatingSystems();
    final list = (osData['os'] as List?) ?? const [];

    final oses = list
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();

    final matches = <int>[];
    final pushUnique = (int osId) {
      if (!matches.contains(osId)) {
        matches.add(osId);
      }
    };

    bool matchesCondition(String text, String expected) {
      return text.toLowerCase().contains(expected.toLowerCase());
    }

    for (final os in oses) {
      final name = (os['name'] ?? '').toString();
      final family = (os['family'] ?? '').toString();
      final id = _intValue(os, const ['id']);
      if (_stringIsEmpty(name) || id <= 0) {
        continue;
      }

      if (matchesCondition(name, 'debian') && matchesCondition(name, '11')) {
        pushUnique(id);
      }
      if (matchesCondition(family, 'ubuntu') &&
          matchesCondition(name, '20.04')) {
        pushUnique(id);
      }
      if (matchesCondition(family, 'debian')) {
        pushUnique(id);
      }
      if (matchesCondition(family, 'ubuntu')) {
        pushUnique(id);
      }
    }

    if (matches.isNotEmpty) {
      return matches;
    }

    for (final os in oses) {
      final id = _intValue(os, const ['id']);
      if (id > 0) {
        pushUnique(id);
      }
    }

    return matches;
  }

  String _messageFromError(Object error) {
    if (error is StateError) {
      return error.message.toString();
    }
    return error.toString();
  }

  bool _shouldKeepApiKeyOnError(Object error) {
    final message = _messageFromError(error).toLowerCase();
    const authIndicators = [
      '401',
      '403',
      'permission denied',
      'forbidden',
      'unauthorized',
      'invalid api key',
    ];
    const transientIndicators = [
      'timeout',
      'connection failed',
      'connection refused',
      'socket exception',
      'failed host lookup',
      'failed to connect',
      'network is unreachable',
      'operation canceled',
      'certificate',
    ];

    if (authIndicators.any((needle) => message.contains(needle))) {
      return false;
    }

    if (transientIndicators.any((needle) => message.contains(needle))) {
      return true;
    }

    return false;
  }

  int _intValue(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value != null) {
        final parsed = int.tryParse(value.toString());
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return 0;
  }

  bool _stringIsEmpty(String? value) {
    return value == null || value.trim().isEmpty;
  }
}

class _VultrNodeRecord {
  final String instanceId;
  final String label;
  final String region;
  final String plan;
  final int osId;
  final int ssPort;
  final String ssPassword;
  final int hyPort;
  final String hyPassword;
  final String hyServerName;
  final int vlessPort;
  final String vlessUuid;
  final String vlessPublicKey;
  final String vlessShortId;
  final String vlessServerName;
  final int trojanPort;
  final String trojanPassword;
  final String trojanServerName;
  final String ipv4;
  final String ipv6;
  final String createdAt;
  final String portProfile;
  final int planRam;

  _VultrNodeRecord({
    required this.instanceId,
    this.label = '',
    this.region = '',
    this.plan = '',
    this.osId = 0,
    this.ssPort = 0,
    this.ssPassword = '',
    this.hyPort = 0,
    this.hyPassword = '',
    this.hyServerName = '',
    this.vlessPort = 0,
    this.vlessUuid = '',
    this.vlessPublicKey = '',
    this.vlessShortId = '',
    this.vlessServerName = '',
    this.trojanPort = 0,
    this.trojanPassword = '',
    this.trojanServerName = '',
    this.ipv4 = '',
    this.ipv6 = '',
    this.createdAt = '',
    this.portProfile = PortProfileAllocator.randomProfile,
    this.planRam = 0,
  });

  CloudInstance toCloudInstance() {
    return CloudInstance(
      id: instanceId,
      provider: 'vultr',
      label: label,
      status: 'unknown',
      region: region,
      plan: plan,
      ipv4: _stringOrNull(ipv4),
      ipv6: _stringOrNull(ipv6),
      createdAt: _parseTime(createdAt),
      nodeInfo: NodeInfo(
        ssPort: ssPort,
        ssPassword: ssPassword,
        hyPort: hyPort,
        hyPassword: hyPassword,
        hyServerName: hyServerName,
        hyInsecure: true,
        vlessPort: vlessPort,
        vlessUuid: vlessUuid,
        vlessPublicKey: vlessPublicKey,
        vlessShortId: vlessShortId,
        vlessServerName: vlessServerName,
        trojanPort: trojanPort,
        trojanPassword: trojanPassword,
        trojanServerName: trojanServerName,
        trojanInsecure: true,
      ),
    );
  }

  _VultrNodeRecord copyWithJson(Map<String, dynamic> values) {
    return _VultrNodeRecord(
      instanceId: instanceId,
      label: (values['label'] ?? label).toString(),
      region: (values['region'] ?? region).toString(),
      plan: (values['plan'] ?? plan).toString(),
      osId: _toInt(values['osId'], defaultValue: osId),
      ssPort: _toInt(values['ssPort'], defaultValue: ssPort),
      ssPassword: (values['ssPassword'] ?? ssPassword).toString(),
      hyPort: _toInt(values['hyPort'], defaultValue: hyPort),
      hyPassword: (values['hyPassword'] ?? hyPassword).toString(),
      hyServerName: (values['hysteriaServerName'] ?? hyServerName).toString(),
      vlessPort: _toInt(values['vlessPort'], defaultValue: vlessPort),
      vlessUuid: (values['vlessUUID'] ?? vlessUuid).toString(),
      vlessPublicKey: (values['vlessPublicKey'] ?? vlessPublicKey).toString(),
      vlessShortId: (values['vlessShortId'] ?? vlessShortId).toString(),
      vlessServerName:
          (values['vlessServerName'] ?? vlessServerName).toString(),
      trojanPort: _toInt(values['trojanPort'], defaultValue: trojanPort),
      trojanPassword: (values['trojanPassword'] ?? trojanPassword).toString(),
      trojanServerName:
          (values['trojanServerName'] ?? trojanServerName).toString(),
      ipv4: (values['ipv4'] ?? ipv4).toString(),
      ipv6: (values['ipv6'] ?? ipv6).toString(),
      createdAt: (values['createdAt'] ?? createdAt).toString(),
      portProfile: (values['portProfile'] ?? portProfile).toString(),
      planRam: _toInt(values['planRam'], defaultValue: planRam),
    );
  }

  Map<String, dynamic> toMergeableJson() {
    final result = <String, dynamic>{
      'id': instanceId,
      'provider': 'vultr',
      'ssPort': ssPort,
      'ssPassword': ssPassword,
      'hysteriaPort': hyPort,
      'hysteriaPassword': hyPassword,
      'hysteriaServerName': hyServerName,
      'vlessPort': vlessPort,
      'vlessUUID': vlessUuid,
      'vlessPublicKey': vlessPublicKey,
      'vlessShortId': vlessShortId,
      'vlessServerName': vlessServerName,
      'trojanPort': trojanPort,
      'trojanPassword': trojanPassword,
      'trojanServerName': trojanServerName,
    };

    if (label.isNotEmpty) {
      result['label'] = label;
    }
    if (region.isNotEmpty) {
      result['region'] = region;
    }
    if (plan.isNotEmpty) {
      result['plan'] = plan;
    }
    if (ipv4.isNotEmpty && ipv4 != '0.0.0.0') {
      result['main_ip'] = ipv4;
    }
    if (ipv6.isNotEmpty) {
      result['v6_main_ip'] = ipv6;
    }
    if (createdAt.isNotEmpty) {
      result['createdAt'] = createdAt;
    }

    return result;
  }

  Map<String, dynamic> toJson() => {
        'instanceId': instanceId,
        'label': label,
        'region': region,
        'plan': plan,
        'osId': osId,
        'ssPort': ssPort,
        'ssPassword': ssPassword,
        'hyPort': hyPort,
        'hyPassword': hyPassword,
        'hysteriaServerName': hyServerName,
        'vlessPort': vlessPort,
        'vlessUUID': vlessUuid,
        'vlessPublicKey': vlessPublicKey,
        'vlessShortId': vlessShortId,
        'vlessServerName': vlessServerName,
        'trojanPort': trojanPort,
        'trojanPassword': trojanPassword,
        'trojanServerName': trojanServerName,
        'ipv4': ipv4,
        'ipv6': ipv6,
        'createdAt': createdAt,
        'portProfile': portProfile,
        'planRam': planRam,
      };

  static _VultrNodeRecord fromJson(
    String instanceId,
    Map<String, dynamic> json,
  ) {
    return _VultrNodeRecord(
      instanceId: instanceId,
      label: (json['label'] ?? '').toString(),
      region: (json['region'] ?? '').toString(),
      plan: (json['plan'] ?? '').toString(),
      osId: _toInt(json['osId']),
      ssPort: _toInt(json['ssPort']),
      ssPassword: (json['ssPassword'] ?? '').toString(),
      hyPort: _toInt(json['hyPort']),
      hyPassword: (json['hyPassword'] ?? '').toString(),
      hyServerName: (json['hysteriaServerName'] ?? '').toString(),
      vlessPort: _toInt(json['vlessPort']),
      vlessUuid: (json['vlessUUID'] ?? '').toString(),
      vlessPublicKey: (json['vlessPublicKey'] ?? '').toString(),
      vlessShortId: (json['vlessShortId'] ?? '').toString(),
      vlessServerName: (json['vlessServerName'] ?? '').toString(),
      trojanPort: _toInt(json['trojanPort']),
      trojanPassword: (json['trojanPassword'] ?? '').toString(),
      trojanServerName: (json['trojanServerName'] ?? '').toString(),
      ipv4: (json['ipv4'] ?? '').toString(),
      ipv6: (json['ipv6'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      portProfile: (json['portProfile'] ?? PortProfileAllocator.randomProfile)
          .toString(),
      planRam: _toInt(json['planRam']),
    );
  }

  static int _toInt(dynamic value, {int defaultValue = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? defaultValue;
    }
    return defaultValue;
  }

  static String? _stringOrNull(String value) {
    if (value.isEmpty) {
      return null;
    }
    return value;
  }

  static DateTime? _parseTime(String value) {
    if (value.isEmpty) {
      return null;
    }
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }
}
