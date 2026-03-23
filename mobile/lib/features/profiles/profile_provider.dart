import 'dart:convert';
import 'dart:io';
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
  late final Future<void> _initialization;

  List<Profile> get profiles => _profiles;
  Profile? get activeProfile => _activeProfile;
  bool get isLoading => _isLoading;
  String? get error => _error;

  ProfileProvider() {
    _initialization = _init();
  }

  Future<void> _init() async {
    await _openBoxIfNeeded();
    _loadProfilesFromBox();
    _loadActiveProfileFromBox();
  }

  Box get _box => Hive.box(_boxName);

  Future<void> _openBoxIfNeeded() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  Future<void> _ensureInitialized() async {
    await _initialization;
    await _openBoxIfNeeded();
  }

  void _loadProfilesFromBox() {
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
  }

  void _loadActiveProfileFromBox() {
    final activeId = _box.get(_activeKey) as String?;
    if (activeId != null) {
      _activeProfile = _profiles.where((p) => p.id == activeId).firstOrNull;
    } else {
      _activeProfile = null;
    }
  }

  Future<void> loadProfiles() async {
    await _ensureInitialized();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _loadProfilesFromBox();
      AppLogger.info(
          '[ProfileProvider] Loaded ${_profiles.length} profiles from local storage');
    } catch (e) {
      _error = 'Failed to load profiles: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Load error', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadActiveProfile() async {
    await _ensureInitialized();
    try {
      _loadActiveProfileFromBox();
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
    await _ensureInitialized();
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
      await _box.flush();
      await loadProfiles();

      // Auto-activate if first profile
      if (_profiles.length == 1) {
        await activateProfile(id);
      }

      AppLogger.info('[ProfileProvider] Created profile $id (${profile.name})');
      return true;
    } catch (e) {
      _error = 'Failed to create profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Create error', e);
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
    await _ensureInitialized();
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
      await _box.flush();
      await loadProfiles();
      await loadActiveProfile();
      return true;
    } catch (e) {
      _error = 'Failed to update profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Update error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> deleteProfile(String id) async {
    await _ensureInitialized();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _box.delete(id);
      await _box.flush();
      _profiles.removeWhere((p) => p.id == id);
      if (_activeProfile?.id == id) {
        _activeProfile = null;
        await _box.delete(_activeKey);
        await _box.flush();
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to delete profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Delete error', e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> activateProfile(String id) async {
    await _ensureInitialized();
    try {
      await _box.put(_activeKey, id);
      await _box.flush();
      _activeProfile = _profiles.where((p) => p.id == id).firstOrNull;
      _profiles =
          _profiles.map((p) => p.copyWith(isActive: p.id == id)).toList();
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to activate profile: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Activate error', e);
      return false;
    }
  }

  Future<String?> getProfileContent(String id) async {
    await _ensureInitialized();
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
    await _ensureInitialized();
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
      await _box.flush();
      await loadProfiles();
      return true;
    } catch (e) {
      _error = 'Failed to save profile content: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Save content error', e);
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
      var changed = false;
      final inbounds = decoded['inbounds'];
      if (inbounds is List) {
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
      }

      final unsupportedTags = <String>{};
      final outbounds = decoded['outbounds'];
      if (outbounds is List) {
        outbounds.removeWhere((outbound) {
          if (outbound is! Map<String, dynamic>) {
            return false;
          }
          if (!_isUnsupportedAndroidOutbound(outbound)) {
            return false;
          }
          final tag = outbound['tag']?.toString();
          if (tag != null && tag.isNotEmpty) {
            unsupportedTags.add(tag);
          }
          changed = true;
          return true;
        });

        while (unsupportedTags.isNotEmpty) {
          var passChanged = false;
          outbounds.removeWhere((outbound) {
            if (outbound is! Map<String, dynamic>) {
              return false;
            }
            final refs = outbound['outbounds'];
            if (refs is! List) {
              return false;
            }

            final before = refs.length;
            refs.removeWhere(
                (value) => unsupportedTags.contains(value?.toString()));
            if (refs.length != before) {
              changed = true;
              passChanged = true;
            }

            final defaultTag = outbound['default']?.toString();
            if (refs.isNotEmpty &&
                defaultTag != null &&
                defaultTag.isNotEmpty &&
                !refs.any((value) => value?.toString() == defaultTag)) {
              outbound['default'] = refs.first.toString();
              changed = true;
              passChanged = true;
            }

            if (refs.isNotEmpty) {
              return false;
            }

            final tag = outbound['tag']?.toString();
            if (tag != null && tag.isNotEmpty) {
              unsupportedTags.add(tag);
            }
            changed = true;
            passChanged = true;
            return true;
          });

          if (!passChanged) {
            break;
          }
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

  static bool _isUnsupportedAndroidOutbound(Map<String, dynamic> outbound) {
    final type = outbound['type']?.toString();
    if (type == 'hysteria2') {
      return true;
    }
    if (type != 'vless') {
      return false;
    }

    final tls = outbound['tls'];
    if (tls is! Map) {
      return false;
    }

    return _isFeatureEnabled(tls['utls']) || _isFeatureEnabled(tls['reality']);
  }

  static bool _isFeatureEnabled(dynamic value) {
    if (value is Map) {
      final enabled = value['enabled'];
      if (enabled is bool) {
        return enabled;
      }
      return enabled?.toString().toLowerCase() == 'true';
    }
    return false;
  }

  /// Import a profile from a JSON file on device storage
  Future<bool> importFromFile(String filePath, {String? name}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _error = 'File not found: $filePath';
        notifyListeners();
        return false;
      }
      final content = await file.readAsString();
      // Validate JSON
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        _error = 'Invalid config: not a JSON object';
        notifyListeners();
        return false;
      }
      final profileName =
          name ?? 'Imported ${DateTime.now().toString().substring(0, 16)}';
      return await createProfile(name: profileName, content: content);
    } catch (e) {
      _error = 'Failed to import from file: $e';
      notifyListeners();
      return false;
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
      lastUpdated:
          parseDate(json['last_updated']) ?? parseDate(json['lastUpdated']),
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
