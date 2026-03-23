import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../shared/utils/logger.dart';
import 'cloud_models.dart';

class CloudProvider with ChangeNotifier {
  static const _providerName = 'vultr';

  List<CloudInstance> _instances = [];
  List<CloudRegion> _regions = [];
  List<CloudPlan> _plans = [];
  bool _isLoading = false;
  bool _configLoaded = false;
  bool _hasApiKey = false;
  String? _error;

  List<CloudInstance> get instances => _instances;
  List<CloudRegion> get regions => _regions;
  List<CloudPlan> get plans => _plans;
  bool get isLoading => _isLoading;
  bool get configLoaded => _configLoaded;
  String? get error => _error;
  bool get hasApiKey => _hasApiKey;
  String? get apiKey => null;

  CloudProvider() {
    _init();
  }

  Future<void> _init() async {
    await refreshCloudConfig(notify: false);
    notifyListeners();
  }

  ApiClient _apiClient() => ApiClient(DioClient.createDio());

  Future<void> refreshCloudConfig({bool notify = true}) async {
    try {
      final data = _unwrapData(await _apiClient().getCloudConfig());
      _hasApiKey = data['hasApiKey'] == true;
      _configLoaded = true;
      _error = null;
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
      _unwrapData(await _apiClient().setActiveProvider(_providerName));
      _unwrapData(await _apiClient().saveCloudConfig({
        'provider': _providerName,
        'apiKey': key.trim(),
      }));

      await refreshCloudConfig(notify: false);
      await loadRegions(notify: false);
      await loadPlans(notify: false);
      return true;
    } catch (e) {
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
      final data = _unwrapData(await _apiClient().getInstances());
      final rawInstances = (data['instances'] as List?) ?? const [];
      _instances = rawInstances
          .whereType<Map>()
          .map(
              (item) => CloudInstance.fromJson(Map<String, dynamic>.from(item)))
          .toList();
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

  Future<void> loadRegions({bool notify = true}) async {
    if (!await _ensureAuthorizedCloudAccess(notify: notify)) {
      return;
    }

    try {
      final data = _unwrapData(await _apiClient().getRegions());
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
      final data = _unwrapData(await _apiClient().getPlans());
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
      _unwrapData(await _apiClient().createInstance({
        'label': label,
        'region': region,
        'plan': plan,
      }));
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
      _unwrapData(await _apiClient().deleteInstance(id));
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
    _error = null;
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

  Map<String, dynamic> _unwrapData(Map<String, dynamic> response) {
    if (response['success'] != true) {
      throw StateError(_messageFromResponse(response));
    }

    final data = response['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return const {};
  }

  String _messageFromResponse(Map<String, dynamic> response) {
    final message = response['message'];
    if (message is String && message.isNotEmpty) {
      return message;
    }

    final error = response['error'];
    if (error is Map<String, dynamic>) {
      final errorMessage = error['message'];
      if (errorMessage is String && errorMessage.isNotEmpty) {
        return errorMessage;
      }
    }

    return 'Request failed';
  }

  String _messageFromError(Object error) {
    if (error is StateError) {
      return error.message.toString();
    }
    return error.toString();
  }
}
