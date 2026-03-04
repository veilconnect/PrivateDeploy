import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../shared/utils/logger.dart';

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

  String _extractError(Map<String, dynamic> response, String fallback) {
    final message = response['message'];
    if (message is String && message.isNotEmpty) return message;
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      final errMsg = error['message'];
      if (errMsg is String && errMsg.isNotEmpty) return errMsg;
    }
    return fallback;
  }

  List<dynamic> _extractProfiles(dynamic data) {
    if (data is List) return data;
    if (data is Map<String, dynamic>) {
      final profiles = data['profiles'];
      if (profiles is List) return profiles;
    }
    return const [];
  }

  Profile? _findActiveFromList() {
    for (final profile in _profiles) {
      if (profile.isActive) {
        return profile;
      }
    }
    return null;
  }

  /// 加载所有配置文件
  Future<void> loadProfiles() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      AppLogger.info('[ProfileProvider] Loading profiles...');
      final response = await apiClient.getProfiles();

      if (response['success'] == true) {
        final profilesData = _extractProfiles(response['data']);
        _profiles = profilesData.map((p) => Profile.fromJson(p)).toList();
        _activeProfile = _findActiveFromList();
        AppLogger.info('[ProfileProvider] Loaded ${_profiles.length} profiles');
      } else {
        _error = _extractError(response, 'Failed to load profiles');
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
        final data = response['data'];
        if (data is Map<String, dynamic>) {
          _activeProfile = Profile.fromJson(data);
        }
        AppLogger.info('[ProfileProvider] Active profile: ${_activeProfile?.name}');
        notifyListeners();
      } else {
        _activeProfile = _findActiveFromList();
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
        _error = _extractError(response, 'Failed to create profile');
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
        _error = _extractError(response, 'Failed to update profile');
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
        _error = _extractError(response, 'Failed to delete profile');
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
        for (final profile in _profiles) {
          if (profile.id == id) {
            _activeProfile = profile.copyWith(isActive: true);
          }
        }
        _profiles = _profiles
            .map((p) => p.copyWith(isActive: p.id == id))
            .toList();
        notifyListeners();
        return true;
      } else {
        _error = _extractError(response, 'Failed to activate profile');
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
        _error = _extractError(response, 'Failed to update subscription');
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
        final data = response['data'];
        if (data is String) return data;
        if (data is Map<String, dynamic>) {
          final content = data['content'];
          if (content is String) return content;
        }
        return null;
      } else {
        _error = _extractError(response, 'Failed to get profile content');
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
        _error = _extractError(response, 'Failed to save profile content');
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

  Profile copyWith({
    String? id,
    String? name,
    String? subscriptionUrl,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastUpdated,
  }) {
    return Profile(
      id: id ?? this.id,
      name: name ?? this.name,
      subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  factory Profile.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    return Profile(
      id: (json['id'] ?? '').toString(),
      name: json['name'] ?? '',
      subscriptionUrl: json['subscription_url'] ?? json['subscriptionUrl'],
      isActive: (json['is_active'] ?? json['active'] ?? false) == true,
      createdAt: parseDate(json['created_at']) ??
          parseDate(json['createdAt']) ??
          DateTime.now(),
      updatedAt: parseDate(json['updated_at']) ??
          parseDate(json['updatedAt']) ??
          DateTime.now(),
      lastUpdated: parseDate(json['last_updated']) ?? parseDate(json['lastUpdated']),
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
