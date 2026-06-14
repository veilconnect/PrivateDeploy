import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/utils/logger.dart';

class StorageService {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static late SharedPreferences _prefs;
  static bool _initialized = false;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  static bool get isInitialized => _initialized;

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

  static Future<bool> saveSecureString(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      return true;
    } on PlatformException catch (error) {
      AppLogger.warning(
        '[StorageService] Secure storage write failed for "$key"; falling back to app preferences: ${error.message ?? error.code}',
      );
      await _prefs.setString(key, value);
      return false;
    }
  }

  static Future<String?> getSecureString(String key) async {
    try {
      return await _secureStorage.read(key: key) ?? _prefs.getString(key);
    } on PlatformException catch (error) {
      AppLogger.warning(
        '[StorageService] Secure storage read failed for "$key"; treating it as unavailable: ${error.message ?? error.code}',
      );
      return _prefs.getString(key);
    }
  }

  static Future<bool> saveSecureStringStrict(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      return true;
    } catch (error) {
      AppLogger.warning(
        '[StorageService] Strict secure storage write failed for "$key"; refusing plaintext fallback: $error',
      );
      return false;
    }
  }

  static Future<String?> getSecureStringStrict(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (error) {
      AppLogger.warning(
        '[StorageService] Strict secure storage read failed for "$key": $error',
      );
      return null;
    }
  }

  static Future<void> removeSecure(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } on PlatformException catch (error) {
      AppLogger.warning(
        '[StorageService] Secure storage delete failed for "$key": ${error.message ?? error.code}',
      );
    }
    // saveSecureString falls back to _prefs when the keystore throws, and
    // getSecureString reads `secure ?? prefs`. Deleting only from the keystore
    // would leave a fallback-stored secret (e.g. a CF API token) readable
    // forever after a "clear", so always clear the prefs mirror too.
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
}
