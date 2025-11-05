import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/storage_service.dart';

class CloudProvider with ChangeNotifier {
  List<CloudProviderInfo> _providers = [];
  CloudProviderInfo? _activeProvider;
  List<CloudInstance> _instances = [];
  List<CloudRegion> _regions = [];
  List<CloudPlan> _plans = [];
  bool _isLoading = false;
  String? _error;

  List<CloudProviderInfo> get providers => _providers;
  CloudProviderInfo? get activeProvider => _activeProvider;
  List<CloudInstance> get instances => _instances;
  List<CloudRegion> get regions => _regions;
  List<CloudPlan> get plans => _plans;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> loadProviders() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final token = StorageService.getToken();
      if (token == null) throw Exception('Not authenticated');

      final dio = DioClient.createDio(token: token);
      final apiClient = ApiClient(dio);
      
      final response = await apiClient.getProviders();
      
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final providersData = data['providers'] as List;
        
        _providers = providersData
            .map((p) => CloudProviderInfo.fromJson(p))
            .toList();
        
        _isLoading = false;
        notifyListeners();
      } else {
        throw Exception(response['error']?['message'] ?? 'Failed to load providers');
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadInstances() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final token = StorageService.getToken();
      if (token == null) throw Exception('Not authenticated');

      final dio = DioClient.createDio(token: token);
      final apiClient = ApiClient(dio);
      
      final response = await apiClient.getInstances();
      
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final instancesData = data['instances'] as List;
        
        _instances = instancesData
            .map((i) => CloudInstance.fromJson(i))
            .toList();
        
        _isLoading = false;
        notifyListeners();
      } else {
        throw Exception(response['error']?['message'] ?? 'Failed to load instances');
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadRegions() async {
    try {
      final token = StorageService.getToken();
      if (token == null) throw Exception('Not authenticated');

      final dio = DioClient.createDio(token: token);
      final apiClient = ApiClient(dio);
      
      final response = await apiClient.getRegions();
      
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final regionsData = data['regions'] as List;
        
        _regions = regionsData
            .map((r) => CloudRegion.fromJson(r))
            .toList();
        
        notifyListeners();
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<bool> createInstance({
    required String region,
    required String plan,
    required String label,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final token = StorageService.getToken();
      if (token == null) throw Exception('Not authenticated');

      final dio = DioClient.createDio(token: token);
      final apiClient = ApiClient(dio);
      
      final response = await apiClient.createInstance({
        'region': region,
        'plan': plan,
        'label': label,
      });
      
      if (response['success'] == true) {
        _isLoading = false;
        await loadInstances(); // Reload instances
        return true;
      } else {
        throw Exception(response['error']?['message'] ?? 'Failed to create instance');
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteInstance(String id) async {
    try {
      final token = StorageService.getToken();
      if (token == null) throw Exception('Not authenticated');

      final dio = DioClient.createDio(token: token);
      final apiClient = ApiClient(dio);
      
      await apiClient.deleteInstance(id);
      await loadInstances(); // Reload instances
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }
}

// Model classes
class CloudProviderInfo {
  final String name;
  final String displayName;

  CloudProviderInfo({
    required this.name,
    required this.displayName,
  });

  factory CloudProviderInfo.fromJson(Map<String, dynamic> json) {
    return CloudProviderInfo(
      name: json['name'] as String,
      displayName: json['displayName'] as String,
    );
  }
}

class CloudInstance {
  final String id;
  final String label;
  final String status;
  final String region;
  final String plan;
  final String? ipv4;
  final String? ipv6;
  final DateTime createdAt;

  CloudInstance({
    required this.id,
    required this.label,
    required this.status,
    required this.region,
    required this.plan,
    this.ipv4,
    this.ipv6,
    required this.createdAt,
  });

  factory CloudInstance.fromJson(Map<String, dynamic> json) {
    return CloudInstance(
      id: json['id'] as String,
      label: json['label'] as String,
      status: json['status'] as String,
      region: json['region'] as String,
      plan: json['plan'] as String,
      ipv4: json['ipv4'] as String?,
      ipv6: json['ipv6'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class CloudRegion {
  final String id;
  final String city;
  final String country;

  CloudRegion({
    required this.id,
    required this.city,
    required this.country,
  });

  factory CloudRegion.fromJson(Map<String, dynamic> json) {
    return CloudRegion(
      id: json['id'] as String,
      city: json['city'] as String,
      country: json['country'] as String,
    );
  }
}

class CloudPlan {
  final String id;
  final int ram;
  final int vcpus;
  final int disk;
  final double? monthlyCost;

  CloudPlan({
    required this.id,
    required this.ram,
    required this.vcpus,
    required this.disk,
    this.monthlyCost,
  });

  factory CloudPlan.fromJson(Map<String, dynamic> json) {
    return CloudPlan(
      id: json['id'] as String,
      ram: json['ram'] as int,
      vcpus: json['vcpus'] as int,
      disk: json['disk'] as int,
      monthlyCost: json['monthlyCost'] as double?,
    );
  }
}
