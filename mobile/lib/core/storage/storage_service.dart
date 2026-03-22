import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/api_constants.dart';

class StorageService {
  static const _tokenKey = 'auth_token';
  static const _apiBaseUrlKey = 'api_base_url';

  static late SharedPreferences _prefs;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static bool _initialized = false;
  static String? _tokenCache;
  static String _apiBaseUrlCache = ApiConstants.defaultBaseUrl;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _tokenCache = await _secureStorage.read(key: _tokenKey);
    _apiBaseUrlCache = _normalizeApiBaseUrl(
      _prefs.getString(_apiBaseUrlKey) ?? ApiConstants.defaultBaseUrl,
    );
    _initialized = true;
  }

  static bool get isInitialized => _initialized;

  // Token management
  static Future<void> saveToken(String token) async {
    _tokenCache = token;
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  static String? getToken() {
    return _tokenCache;
  }

  static Future<void> clearToken() async {
    _tokenCache = null;
    await _secureStorage.delete(key: _tokenKey);
  }

  // API server configuration
  static String getApiBaseUrl() {
    return _apiBaseUrlCache;
  }

  static Future<void> saveApiBaseUrl(String value) async {
    final normalized = _normalizeApiBaseUrl(value);
    _apiBaseUrlCache = normalized;
    await _prefs.setString(_apiBaseUrlKey, normalized);
  }

  static Future<void> clearApiBaseUrl() async {
    _apiBaseUrlCache = ApiConstants.defaultBaseUrl;
    await _prefs.remove(_apiBaseUrlKey);
  }

  // Other storage methods
  static Future<void> saveString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  static String? getString(String key) {
    if (!_initialized) {
      return null;
    }
    return _prefs.getString(key);
  }

  static Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  static Future<void> saveBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  static bool? getBool(String key) {
    if (!_initialized) {
      return null;
    }
    return _prefs.getBool(key);
  }

  static String _normalizeApiBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return ApiConstants.defaultBaseUrl;
    }
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }
}
