import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:privatedeploy_mobile/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureValues = <String, String?>{};
  var failSecureWrites = false;

  void installHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return key == null ? null : secureValues[key];
        case 'write':
          if (failSecureWrites) {
            throw PlatformException(code: 'Keystore unavailable');
          }
          if (key != null) {
            secureValues[key] = call.arguments['value'] as String?;
          }
          return null;
        case 'delete':
          if (key != null) {
            secureValues.remove(key);
          }
          return null;
        case 'deleteAll':
          secureValues.clear();
          return null;
        default:
          return null;
      }
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    failSecureWrites = false;
    installHandler();
    await StorageService.init();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('saveSecureString persists to keystore and not to plaintext', () async {
    final ok = await StorageService.saveSecureString('api_key', 'secret-value');
    expect(ok, isTrue);
    expect(secureValues['api_key'], 'secret-value');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('api_key'), isNull,
        reason: 'secret must not be mirrored into plaintext prefs');
  });

  test('saveSecureString fails closed when keystore is unavailable', () async {
    failSecureWrites = true;
    final ok = await StorageService.saveSecureString('api_key', 'secret-value');
    expect(ok, isFalse, reason: 'must report failure, not silently succeed');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('api_key'), isNull,
        reason: 'no plaintext fallback may be written on keystore failure');
  });

  test('getSecureString migrates a legacy plaintext secret into the keystore',
      () async {
    // Simulate a legacy build that left the secret in plaintext prefs.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('legacy_key', 'legacy-secret');

    final value = await StorageService.getSecureString('legacy_key');
    expect(value, 'legacy-secret');

    // After migration it should live in the keystore and be gone from prefs.
    expect(secureValues['legacy_key'], 'legacy-secret');
    final prefsAfter = await SharedPreferences.getInstance();
    expect(prefsAfter.getString('legacy_key'), isNull);
  });

  test(
      'getSecureString returns the legacy secret and retains it for retry when '
      'the keystore is unavailable during migration', () async {
    // Legacy build left the secret in plaintext, and the keystore now refuses
    // writes (e.g. transiently locked). Reading must NOT lock the user out of
    // their already-stored credential: return the legacy value and keep the
    // plaintext mirror so a later read can retry the migration. This is a
    // backward-compat read path — the fail-closed contract governs WRITES of
    // *new* plaintext (covered above), not destroying already-persisted data.
    failSecureWrites = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('legacy_key', 'legacy-secret');

    final value = await StorageService.getSecureString('legacy_key');
    expect(value, 'legacy-secret',
        reason: 'must not lock the user out of an already-stored secret');

    // Migration could not complete, so the plaintext mirror must remain for a
    // future retry rather than being silently dropped.
    expect(secureValues['legacy_key'], isNull,
        reason: 'keystore write failed, so nothing should be persisted there');
    final prefsAfter = await SharedPreferences.getInstance();
    expect(prefsAfter.getString('legacy_key'), 'legacy-secret',
        reason: 'plaintext must be retained so migration can retry');
  });
}
