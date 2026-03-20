import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../shared/utils/logger.dart';
import 'vultr_api.dart';

class CloudProvider with ChangeNotifier {
  static const String _boxName = 'cloud';
  static const String _apiKeyKey = 'vultr_api_key';
  static const String _nodesKey = 'deployed_nodes';

  VultrApi? _api;
  List<VultrInstance> _instances = [];
  List<VultrRegion> _regions = [];
  List<VultrPlan> _plans = [];
  List<DeployedNode> _deployedNodes = [];
  bool _isLoading = false;
  String? _error;
  String? _apiKey;

  List<VultrInstance> get instances => _instances;
  List<VultrRegion> get regions => _regions;
  List<VultrPlan> get plans => _plans;
  List<DeployedNode> get deployedNodes => _deployedNodes;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;
  String? get apiKey => _apiKey;

  CloudProvider() {
    _init();
  }

  Future<void> _init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
    _apiKey = Hive.box(_boxName).get(_apiKeyKey) as String?;
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      _api = VultrApi(_apiKey!);
    }
    _loadDeployedNodes();
    notifyListeners();
  }

  Box get _box => Hive.box(_boxName);

  Future<bool> setApiKey(String key) async {
    try {
      final api = VultrApi(key);
      final valid = await api.verifyApiKey();
      if (!valid) {
        _error = 'Invalid API key';
        notifyListeners();
        return false;
      }
      _apiKey = key;
      _api = api;
      await _box.put(_apiKeyKey, key);
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to verify API key: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> loadInstances() async {
    if (_api == null) return;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _instances = await _api!.listInstances();
      AppLogger.info('[CloudProvider] Loaded ${_instances.length} instances');

      // Attach local node info
      for (final inst in _instances) {
        final node = _deployedNodes.where((n) => n.instanceId == inst.id).firstOrNull;
        if (node != null) {
          inst.nodeInfo = node.nodeInfo;
        }
      }
    } catch (e) {
      _error = 'Failed to load instances: $e';
      AppLogger.error('[CloudProvider] Load instances error', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadRegions() async {
    if (_api == null) return;
    try {
      _regions = await _api!.listRegions();
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load regions: $e';
      notifyListeners();
    }
  }

  Future<void> loadPlans() async {
    if (_api == null) return;
    try {
      _plans = await _api!.listPlans();
      // Filter to affordable plans
      _plans = _plans.where((p) => p.monthlyCost <= 24 && p.monthlyCost > 0).toList();
      _plans.sort((a, b) => a.monthlyCost.compareTo(b.monthlyCost));
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load plans: $e';
      notifyListeners();
    }
  }

  Future<bool> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    if (_api == null) {
      _error = 'API key not configured';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final instance = await _api!.createInstance(
        region: region,
        plan: plan,
        label: label,
      );

      // Save node info locally
      if (instance.nodeInfo != null) {
        final node = DeployedNode(
          instanceId: instance.id,
          label: label,
          region: region,
          nodeInfo: instance.nodeInfo!,
          createdAt: DateTime.now(),
        );
        _deployedNodes.add(node);
        _saveDeployedNodes();
      }

      await loadInstances();
      return true;
    } catch (e) {
      _error = 'Failed to create instance: $e';
      AppLogger.error('[CloudProvider] Create instance error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteInstance(String id) async {
    if (_api == null) return false;

    try {
      await _api!.deleteInstance(id);
      _deployedNodes.removeWhere((n) => n.instanceId == id);
      _saveDeployedNodes();
      await loadInstances();
      return true;
    } catch (e) {
      _error = 'Failed to delete instance: $e';
      notifyListeners();
      return false;
    }
  }

  /// Generate sing-box config for a deployed node
  String? generateNodeConfig(VultrInstance instance) {
    if (!instance.hasIp || instance.nodeInfo == null) return null;
    final ip = instance.mainIp!;
    final info = instance.nodeInfo!;
    final label = instance.label;

    final outbounds = <Map<String, dynamic>>[];
    final tags = <String>[];

    // Shadowsocks
    final ssTag = '$label-SS';
    outbounds.add({
      'type': 'shadowsocks',
      'tag': ssTag,
      'server': ip,
      'server_port': info.ssPort,
      'method': 'aes-256-gcm',
      'password': info.ssPassword,
    });
    tags.add(ssTag);

    // Hysteria2
    final hyTag = '$label-Hy2';
    outbounds.add({
      'type': 'hysteria2',
      'tag': hyTag,
      'server': ip,
      'server_port': info.hyPort,
      'password': info.hyPassword,
      'tls': {
        'enabled': true,
        'server_name': ip,
        'insecure': true,
      },
    });
    tags.add(hyTag);

    // VLESS
    final vlessTag = '$label-VLESS';
    outbounds.add({
      'type': 'vless',
      'tag': vlessTag,
      'server': ip,
      'server_port': info.vlessPort,
      'uuid': info.vlessUuid,
      'flow': 'xtls-rprx-vision',
    });
    tags.add(vlessTag);

    // Trojan
    final trojanTag = '$label-Trojan';
    outbounds.add({
      'type': 'trojan',
      'tag': trojanTag,
      'server': ip,
      'server_port': info.trojanPort,
      'password': info.trojanPassword,
      'tls': {
        'enabled': true,
        'server_name': ip,
        'insecure': true,
      },
    });
    tags.add(trojanTag);

    final config = {
      'log': {'level': 'info'},
      'dns': {
        'servers': [
          {'tag': 'dns-remote', 'address': 'https://8.8.8.8/dns-query', 'detour': 'select'},
          {'tag': 'dns-local', 'address': 'local'},
        ],
        'rules': [
          {'outbound': ['any'], 'server': 'dns-local'},
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
          {'geoip': ['private'], 'outbound': 'direct'},
        ],
        'auto_detect_interface': true,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  void _loadDeployedNodes() {
    try {
      final raw = _box.get(_nodesKey) as String?;
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _deployedNodes = list.map((j) => DeployedNode.fromJson(j)).toList();
      }
    } catch (e) {
      AppLogger.error('[CloudProvider] Load deployed nodes error', e);
    }
  }

  void _saveDeployedNodes() {
    try {
      final json = _deployedNodes.map((n) => n.toJson()).toList();
      _box.put(_nodesKey, jsonEncode(json));
    } catch (e) {
      AppLogger.error('[CloudProvider] Save deployed nodes error', e);
    }
  }
}

class DeployedNode {
  final String instanceId;
  final String label;
  final String region;
  final NodeInfo nodeInfo;
  final DateTime createdAt;

  DeployedNode({
    required this.instanceId,
    required this.label,
    required this.region,
    required this.nodeInfo,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'instance_id': instanceId,
    'label': label,
    'region': region,
    'node_info': nodeInfo.toJson(),
    'created_at': createdAt.toIso8601String(),
  };

  factory DeployedNode.fromJson(Map<String, dynamic> json) => DeployedNode(
    instanceId: json['instance_id'] ?? '',
    label: json['label'] ?? '',
    region: json['region'] ?? '',
    nodeInfo: NodeInfo.fromJson(json['node_info'] ?? {}),
    createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
  );
}
