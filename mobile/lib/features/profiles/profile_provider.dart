import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../shared/utils/logger.dart';
import 'bundled_rule_set_registry.dart';
import 'profile_config_normalizer.dart';
import 'profile_model.dart';
import '../settings/app_settings_provider.dart';

export 'profile_model.dart';

class ProfileProvider with ChangeNotifier {
  static const String _boxName = 'profiles';
  static const String _activeKey = 'active_profile_id';
  static const String cloudManagedProfilePrefix = 'Cloud: ';

  List<Profile> _profiles = [];
  Profile? _activeProfile;
  bool _isLoading = false;
  String? _error;
  late final Future<void> _initialization;

  List<Profile> get profiles => _profiles;
  Profile? get activeProfile => _activeProfile;
  bool get isLoading => _isLoading;
  String? get error => _error;

  static bool isCloudManagedProfileName(String name) {
    return name.startsWith(cloudManagedProfilePrefix);
  }

  Profile? getProfileByName(String name) {
    return _profiles.where((p) => p.name == name).firstOrNull;
  }

  String? validateProfileName(
    String name, {
    String? excludeId,
    bool allowReservedPrefix = false,
  }) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return 'Profile name cannot be empty';
    }
    if (!allowReservedPrefix && isCloudManagedProfileName(trimmedName)) {
      return 'Profile names cannot start with "$cloudManagedProfilePrefix"';
    }

    final hasDuplicate = _profiles.any(
      (profile) => profile.id != excludeId && profile.name == trimmedName,
    );
    if (hasDuplicate) {
      return 'A profile with this name already exists';
    }
    return null;
  }

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
    bool allowReservedPrefix = false,
  }) async {
    await _ensureInitialized();
    final normalizedName = name.trim();
    final validationError = validateProfileName(
      normalizedName,
      allowReservedPrefix: allowReservedPrefix,
    );
    if (validationError != null) {
      _error = validationError;
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final profile = Profile(
        id: id,
        name: normalizedName,
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
    bool allowReservedPrefix = false,
  }) async {
    await _ensureInitialized();
    final normalizedName = name?.trim();
    if (normalizedName != null) {
      final validationError = validateProfileName(
        normalizedName,
        excludeId: id,
        allowReservedPrefix: allowReservedPrefix,
      );
      if (validationError != null) {
        _error = validationError;
        notifyListeners();
        return false;
      }
    }

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
        name: normalizedName,
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

  Future<bool> deleteProfileByName(String name) async {
    await _ensureInitialized();
    final profile = getProfileByName(name);
    if (profile == null) {
      return true;
    }
    return deleteProfile(profile.id);
  }

  Future<int> pruneMissingCloudProfiles(
      Set<String> existingCloudProfileNames) async {
    await _ensureInitialized();
    final staleProfiles = _profiles
        .where(
          (profile) =>
              isCloudManagedProfileName(profile.name) &&
              !existingCloudProfileNames.contains(profile.name),
        )
        .toList();
    if (staleProfiles.isEmpty) {
      return 0;
    }

    final staleIds = staleProfiles.map((profile) => profile.id).toSet();
    try {
      await _box.deleteAll(staleIds);
      await _box.flush();
      _profiles.removeWhere((profile) => staleIds.contains(profile.id));
      if (_activeProfile != null && staleIds.contains(_activeProfile!.id)) {
        _activeProfile = null;
        await _box.delete(_activeKey);
        await _box.flush();
      }
      notifyListeners();
      return staleProfiles.length;
    } catch (e) {
      _error = 'Failed to remove stale cloud profiles: ${e.toString()}';
      AppLogger.error('[ProfileProvider] Prune stale cloud profiles error', e);
      notifyListeners();
      return 0;
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
  String? getActiveConfigJson({
    VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
  }) {
    if (_activeProfile == null) return null;
    final content = _activeProfile!.content;
    if (content == null || content.isEmpty) return null;
    return normalizeConfigForCurrentPlatform(
      content,
      routingSettings: routingSettings,
      bundledRuleSetPaths: BundledRuleSetRegistry.paths,
    );
  }

  @visibleForTesting
  static String normalizeConfigForCurrentPlatform(
    String content, {
    TargetPlatform? targetPlatform,
    VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
    BundledRuleSetPaths bundledRuleSetPaths = const BundledRuleSetPaths(),
  }) {
    return normalizeProfileConfigForCurrentPlatform(
      content,
      targetPlatform: targetPlatform,
      routingSettings: routingSettings,
      bundledRuleSetPaths: bundledRuleSetPaths,
    );
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
