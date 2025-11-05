import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../shared/utils/logger.dart';
import 'package:dio/dio.dart';

class ProfileProvider with ChangeNotifier {
  final ApiClient apiClient;

  List<Profile> _profiles = [];
  Profile? _activeProfile;
  bool _isLoading = false;
  String? _error;

  List<Profile> get profiles => _profiles;
  Profile? get activeProfile => _activeProfile;
  bool get isLoading => _isLoading;
  String? get error => _error;

  ProfileProvider(this.apiClient);

  /// 加载所有配置文件
  Future<void> loadProfiles() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Loading profiles...');
      final response = await apiClient.getProfiles();

      if (response['success'] == true) {
        final profilesData = response['data'] as List;
        _profiles = profilesData.map((p) => Profile.fromJson(p)).toList();
        AppLogger.info('[ProfileProvider] Loaded ${_profiles.length} profiles');
      } else {
        _error = response['message'] ?? 'Failed to load profiles';
        AppLogger.error('[ProfileProvider] Load failed: $_error');
      }
    } catch (e) {
      _error = 'Failed to load profiles: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Load error', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 获取当前激活的配置文件
  Future<void> loadActiveProfile() async {
    try {
      AppLogger.info('[ProfileProvider] Loading active profile...');
      final response = await apiClient.getActiveProfile();

      if (response['success'] == true && response['data'] != null) {
        _activeProfile = Profile.fromJson(response['data']);
        AppLogger.info('[ProfileProvider] Active profile: ${_activeProfile?.name}');
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('[ProfileProvider] Failed to load active profile', e);
    }
  }

  /// 创建新配置文件
  Future<bool> createProfile({
    required String name,
    String? subscriptionUrl,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Creating profile: $name');
      final response = await apiClient.createProfile({
        'name': name,
        if (subscriptionUrl != null) 'subscription_url': subscriptionUrl,
      });

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Profile created successfully');
        await loadProfiles();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to create profile';
        AppLogger.error('[ProfileProvider] Create failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to create profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Create error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 更新配置文件
  Future<bool> updateProfile({
    required String id,
    String? name,
    String? subscriptionUrl,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Updating profile: $id');
      final response = await apiClient.updateProfile(
        id,
        {
          if (name != null) 'name': name,
          if (subscriptionUrl != null) 'subscription_url': subscriptionUrl,
        },
      );

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Profile updated successfully');
        await loadProfiles();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to update profile';
        AppLogger.error('[ProfileProvider] Update failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to update profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Update error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 删除配置文件
  Future<bool> deleteProfile(String id) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Deleting profile: $id');
      final response = await apiClient.deleteProfile(id);

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Profile deleted successfully');
        _profiles.removeWhere((p) => p.id == id);
        if (_activeProfile?.id == id) {
          _activeProfile = null;
        }
        notifyListeners();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to delete profile';
        AppLogger.error('[ProfileProvider] Delete failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to delete profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Delete error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 激活配置文件
  Future<bool> activateProfile(String id) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Activating profile: $id');
      final response = await apiClient.setActiveProfile(id);

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Profile activated successfully');
        _activeProfile = _profiles.firstWhere((p) => p.id == id);
        notifyListeners();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to activate profile';
        AppLogger.error('[ProfileProvider] Activate failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to activate profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Activate error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 更新订阅
  Future<bool> updateSubscription(String id) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Updating subscription for profile: $id');
      final response = await apiClient.updateSubscription(id);

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Subscription updated successfully');
        await loadProfiles();
        return true;
      } else {
        _error = response['message'] ?? 'Failed to update subscription';
        AppLogger.error('[ProfileProvider] Update subscription failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to update subscription: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Update subscription error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 获取配置文件内容
  Future<String?> getProfileContent(String id) async {
    try {
      AppLogger.info('[ProfileProvider] Getting profile content: $id');
      final response = await apiClient.getProfileContent(id);

      if (response['success'] == true) {
        return response['data'] as String?;
      } else {
        _error = response['message'] ?? 'Failed to get profile content';
        AppLogger.error('[ProfileProvider] Get content failed: $_error');
        notifyListeners();
        return null;
      }
    } catch (e) {
      _error = 'Failed to get profile content: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Get content error', e);
      notifyListeners();
      return null;
    }
  }

  /// 保存配置文件内容
  Future<bool> saveProfileContent(String id, String content) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Saving profile content: $id');
      final response = await apiClient.saveProfileContent(id, {'content': content});

      if (response['success'] == true) {
        AppLogger.info('[ProfileProvider] Profile content saved successfully');
        return true;
      } else {
        _error = response['message'] ?? 'Failed to save profile content';
        AppLogger.error('[ProfileProvider] Save content failed: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to save profile content: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Save content error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

/// 配置文件数据模型
class Profile {
  final String id;
  final String name;
  final String? subscriptionUrl;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUpdated;

  Profile({
    required this.id,
    required this.name,
    this.subscriptionUrl,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    this.lastUpdated,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      subscriptionUrl: json['subscription_url'],
      isActive: json['is_active'] ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'])
          : DateTime.now(),
      lastUpdated: json['last_updated'] != null
          ? DateTime.parse(json['last_updated'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'subscription_url': subscriptionUrl,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }
}
