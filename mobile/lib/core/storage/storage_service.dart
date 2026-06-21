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

  // saveSecureString writes a secret to the platform keystore only. It is
  // fail-closed: if the keystore is unavailable it returns false WITHOUT
  // mirroring the secret into plaintext SharedPreferences. Callers must treat
  // a false return as "the secret could not be stored" and surface that to the
  // user rather than assuming it was persisted.
  static Future<bool> saveSecureString(String key, String value) async {
    final ok = await saveSecureStringStrict(key, value);
    if (ok) {
      // A prior build may have left a plaintext mirror for this key. Now that
      // the secret lives in the keystore, drop the plaintext copy.
      await _prefs.remove(key);
    }
    return ok;
  }

  // getSecureString reads from the platform keystore. For backward
  // compatibility it performs a one-time migration of any legacy plaintext
  // value that an older (insecure-fallback) build may have written: on read it
  // moves the value into the keystore and clears the plaintext mirror. It never
  // writes new plaintext.
  static Future<String?> getSecureString(String key) async {
    final secure = await getSecureStringStrict(key);
    if (secure != null) {
      return secure;
    }

    // Legacy migration path: an older build may have stored this secret in
    // plaintext SharedPreferences when the keystore threw. Migrate it.
    final legacy = _prefs.getString(key);
    if (legacy == null) {
      return null;
    }
    final migrated = await saveSecureStringStrict(key, legacy);
    if (migrated) {
      await _prefs.remove(key);
      AppLogger.info(
        '[StorageService] Migrated legacy plaintext secret "$key" into the keystore.',
      );
    } else {
      AppLogger.warning(
        '[StorageService] Keystore unavailable; could not migrate legacy secret "$key" off plaintext. Will retry on next read.',
      );
    }
    return legacy;
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
