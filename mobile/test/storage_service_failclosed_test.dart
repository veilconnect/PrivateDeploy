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
}
