import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../shared/utils/logger.dart';

class ProfileProvider with ChangeNotifier {
  static const String _boxName = 'profiles';
  static const String _activeKey = 'active_profile_id';

  List<Profile> _profiles = [];
  Profile? _activeProfile;
  bool _isLoading = false;
  String? _error;

  List<Profile> get profiles => _profiles;
  Profile? get activeProfile => _activeProfile;
  bool get isLoading => _isLoading;
  String? get error => _error;

  ProfileProvider() {
    _init();
  }

  Future<void> _init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
    await loadProfiles();
    await loadActiveProfile();
  }

  Box get _box => Hive.box(_boxName);

  Future<void> loadProfiles() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final keys = _box.keys.where((k) => k != _activeKey).toList();
      _profiles = [];
      for (final key in keys) {
        final raw = _box.get(key);
        if (raw is String) {
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            _profiles.add(Profile.fromJson(json));
          } catch (_) {}
        }
      }
      _profiles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      AppLogger.info('[ProfileProvider] Loaded ${_profiles.length} profiles from local storage');
    } catch (e) {
      _error = 'Failed to load profiles: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Load error', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadActiveProfile() async {
    try {
      final activeId = _box.get(_activeKey) as String?;
      if (activeId != null) {
        _activeProfile = _profiles.where((p) => p.id == activeId).firstOrNull;
      }
      notifyListeners();
    } catch (e) {
      AppLogger.error('[ProfileProvider] Failed to load active profile', e);
    }
  }

  Future<bool> createProfile({
    required String name,
    String? subscriptionUrl,
    String? content,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final profile = Profile(
        id: id,
        name: name,
        subscriptionUrl: subscriptionUrl,
        content: content ?? '',
        isActive: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _box.put(id, jsonEncode(profile.toJson()));
      await loadProfiles();

      // Auto-activate if first profile
      if (_profiles.length == 1) {
        await activateProfile(id);
      }

      return true;
    } catch (e) {
      _error = 'Failed to create profile: ${e.toString()}';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> updateProfile({
    required String id,
    String? name,
    String? subscriptionUrl,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final existing = _profiles.where((p) => p.id == id).firstOrNull;
      if (existing == null) {
        _error = 'Profile not found';
        return false;
      }

      final updated = existing.copyWith(
        name: name,
        subscriptionUrl: subscriptionUrl,
        updatedAt: DateTime.now(),
      );

      await _box.put(id, jsonEncode(updated.toJson()));
      await loadProfiles();
      await loadActiveProfile();
      return true;
    } catch (e) {
      _error = 'Failed to update profile: ${e.toString()}';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteProfile(String id) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _box.delete(id);
      _profiles.removeWhere((p) => p.id == id);
      if (_activeProfile?.id == id) {
        _activeProfile = null;
        await _box.delete(_activeKey);
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to delete profile: ${e.toString()}';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> activateProfile(String id) async {
    try {
      await _box.put(_activeKey, id);
      _activeProfile = _profiles.where((p) => p.id == id).firstOrNull;
      _profiles = _profiles.map((p) => p.copyWith(isActive: p.id == id)).toList();
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to activate profile: ${e.toString()}';
      return false;
    }
  }

  Future<String?> getProfileContent(String id) async {
    try {
      final raw = _box.get(id) as String?;
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return json['content'] as String? ?? '';
      }
      return null;
    } catch (e) {
      _error = 'Failed to get profile content';
      return null;
    }
  }

  Future<bool> saveProfileContent(String id, String content) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final existing = _profiles.where((p) => p.id == id).firstOrNull;
      if (existing == null) {
        _error = 'Profile not found';
        return false;
      }

      final updated = existing.copyWith(
        content: content,
        updatedAt: DateTime.now(),
      );
      await _box.put(id, jsonEncode(updated.toJson()));
      await loadProfiles();
      return true;
    } catch (e) {
      _error = 'Failed to save profile content: ${e.toString()}';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Get the active profile's sing-box config JSON for VPN connection
  String? getActiveConfigJson() {
    if (_activeProfile == null) return null;
    final content = _activeProfile!.content;
    if (content == null || content.isEmpty) return null;
    return normalizeConfigForCurrentPlatform(content);
  }

  @visibleForTesting
  static String normalizeConfigForCurrentPlatform(
    String content, {
    TargetPlatform? targetPlatform,
  }) {
    if ((targetPlatform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return content;
    }

    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return content;
      }
      final inbounds = decoded['inbounds'];
      if (inbounds is! List) {
        return content;
      }

      var changed = false;
      for (final inbound in inbounds) {
        if (inbound is! Map<String, dynamic>) {
          continue;
        }
        if (inbound['type']?.toString() != 'tun') {
          continue;
        }

        final stack = inbound['stack']?.toString().trim();
        if (stack == null || stack.isEmpty || stack == 'system') {
          inbound['stack'] = 'gvisor';
          changed = true;
        }
      }

      if (!changed) {
        return content;
      }
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return content;
    }
  }

  Future<bool> updateSubscription(String id) async {
    _error = 'Subscription update requires network. Please update manually.';
    notifyListeners();
    return false;
  }
}

class Profile {
  final String id;
  final String name;
  final String? subscriptionUrl;
  final String? content;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUpdated;

  Profile({
    required this.id,
    required this.name,
    this.subscriptionUrl,
    this.content,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    this.lastUpdated,
  });

  Profile copyWith({
    String? id,
    String? name,
    String? subscriptionUrl,
    String? content,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastUpdated,
  }) {
    return Profile(
      id: id ?? this.id,
      name: name ?? this.name,
      subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      content: content ?? this.content,
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
      content: json['content'],
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
      'content': content,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }
}
