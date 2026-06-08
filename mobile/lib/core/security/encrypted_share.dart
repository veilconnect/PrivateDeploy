import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String armoredEncryptedSharePrefix = 'PDENC1:';
const String encryptedShareFormat = 'privatedeploy-share';
const int encryptedShareVersion = 1;
const int encryptedSharePbkdf2Iterations = 60000;
const int minimumEncryptedSharePbkdf2Iterations = 1000;

final Cipher _encryptedShareCipher = AesGcm.with256bits();

class EncryptedShareKind {
  static const proxyLinks = 'proxy-links';
  static const profileConfig = 'profile-config';
  static const cloudBackup = 'cloud-backup';

  const EncryptedShareKind._();
}

class EncryptedSharePayload {
  const EncryptedSharePayload({
    required this.kind,
    required this.content,
    this.label,
    this.createdAt,
  });

  final String kind;
  final String content;
  final String? label;
  final DateTime? createdAt;
}

class EncryptedShareCodec {
  const EncryptedShareCodec._();

  static bool looksEncrypted(String raw) {
    return _normalizeArmored(raw).startsWith(armoredEncryptedSharePrefix);
  }

  static Future<String> encrypt({
    required String kind,
    required String content,
    required String passphrase,
    String? label,
    int iterations = encryptedSharePbkdf2Iterations,
  }) async {
    final normalizedPassphrase = passphrase.trim();
    if (normalizedPassphrase.isEmpty) {
      throw const FormatException('Passphrase cannot be empty');
    }
    if (iterations < minimumEncryptedSharePbkdf2Iterations) {
      throw FormatException(
        'PBKDF2 iterations must be at least $minimumEncryptedSharePbkdf2Iterations',
      );
    }

    final payload = jsonEncode({
      'content': content,
      'label': label,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final secretKey = await _deriveKey(
      passphrase: normalizedPassphrase,
      salt: salt,
      iterations: iterations,
    );
    final box = await _encryptedShareCipher.encrypt(
      utf8.encode(payload),
      secretKey: secretKey,
      nonce: nonce,
    );

    final envelope = jsonEncode({
      'format': encryptedShareFormat,
      'version': encryptedShareVersion,
      'kind': kind,
      'kdf': {
        'name': 'pbkdf2-sha256',
        'iterations': iterations,
        'salt': _base64UrlNoPad(salt),
      },
      'cipher': {
        'name': 'aes-256-gcm',
        'nonce': _base64UrlNoPad(nonce),
        'ciphertext': _base64UrlNoPad(box.cipherText),
        'mac': _base64UrlNoPad(box.mac.bytes),
      },
    });
    return '$armoredEncryptedSharePrefix${_base64UrlNoPad(utf8.encode(envelope))}';
  }

  static Future<EncryptedSharePayload> decrypt({
    required String armored,
    required String passphrase,
    String? expectedKind,
  }) async {
    final normalizedPassphrase = passphrase.trim();
    if (normalizedPassphrase.isEmpty) {
      throw const FormatException('Passphrase cannot be empty');
    }

    final envelope = _decodeEnvelope(armored);
    final kind = _readRequiredString(envelope, 'kind');
    if (expectedKind != null && expectedKind != kind) {
      throw FormatException(
          'Share type "$kind" does not match "$expectedKind"');
    }

    final kdf = _readRequiredMap(envelope, 'kdf');
    final iterations = _readRequiredInt(kdf, 'iterations');
    if (iterations < minimumEncryptedSharePbkdf2Iterations) {
      throw FormatException('Unsupported KDF iterations "$iterations"');
    }

    final salt = _decodeRequiredBase64(kdf, 'salt');
    final cipher = _readRequiredMap(envelope, 'cipher');
    final nonce = _decodeRequiredBase64(cipher, 'nonce');
    final ciphertext = _decodeRequiredBase64(cipher, 'ciphertext');
    final mac = _decodeRequiredBase64(cipher, 'mac');

    final secretKey = await _deriveKey(
      passphrase: normalizedPassphrase,
      salt: salt,
      iterations: iterations,
    );

    List<int> clearBytes;
    try {
      clearBytes = await _encryptedShareCipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: secretKey,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'Incorrect passphrase or corrupted encrypted content',
      );
    }

    final decoded = jsonDecode(utf8.decode(clearBytes));
    if (decoded is! Map) {
      throw const FormatException('Encrypted content is not a JSON object');
    }
    final data = Map<String, dynamic>.from(decoded);
    final content = _readRequiredString(data, 'content');
    final label = _readOptionalString(data, 'label');
    final createdAtRaw = _readOptionalString(data, 'createdAt');

    return EncryptedSharePayload(
      kind: kind,
      content: content,
      label: label?.trim().isEmpty == true ? null : label?.trim(),
      createdAt: createdAtRaw == null || createdAtRaw.trim().isEmpty
          ? null
          : DateTime.tryParse(createdAtRaw),
    );
  }

  static Map<String, dynamic> _decodeEnvelope(String raw) {
    final normalized = _normalizeArmored(raw);
    if (!normalized.startsWith(armoredEncryptedSharePrefix)) {
      throw const FormatException(
        'Encrypted content must start with the PrivateDeploy share prefix',
      );
    }

    final encoded =
        normalized.substring(armoredEncryptedSharePrefix.length).trim();
    if (encoded.isEmpty) {
      throw const FormatException('Encrypted content is empty');
    }

    final decoded = jsonDecode(
      utf8.decode(_base64UrlDecode(encoded)),
    );
    if (decoded is! Map) {
      throw const FormatException('Encrypted share envelope must be an object');
    }

    final envelope = Map<String, dynamic>.from(decoded);
    final format = _readRequiredString(envelope, 'format');
    if (format != encryptedShareFormat) {
      throw FormatException('Unsupported share format "$format"');
    }
    final version = _readRequiredInt(
      envelope,
      'version',
      expected: encryptedShareVersion,
    );
    if (version != encryptedShareVersion) {
      throw FormatException('Unsupported share version "$version"');
    }
    return envelope;
  }

  static Future<SecretKey> _deriveKey({
    required String passphrase,
    required List<int> salt,
    required int iterations,
  }) {
    return _createKdf(iterations).deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
  }

  static Pbkdf2 _createKdf(int iterations) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _normalizeArmored(String raw) {
    return raw.replaceAll(RegExp(r'\s+'), '').trim();
  }

  static String _readRequiredString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('"$key" must be a non-empty string');
    }
    return value;
  }

  static String? _readOptionalString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('"$key" must be a string');
    }
    return value;
  }

  static int _readRequiredInt(
    Map<String, dynamic> data,
    String key, {
    int? expected,
  }) {
    final value = data[key];
    if (value is! num) {
      throw FormatException('"$key" must be a number');
    }
    final normalized = value.toInt();
    if (expected != null && normalized != expected) {
      throw FormatException('"$key" must equal $expected');
    }
    return normalized;
  }

  static Map<String, dynamic> _readRequiredMap(
    Map<String, dynamic> data,
    String key,
  ) {
    final value = data[key];
    if (value is! Map) {
      throw FormatException('"$key" must be an object');
    }
    return Map<String, dynamic>.from(value);
  }

  static List<int> _decodeRequiredBase64(
      Map<String, dynamic> data, String key) {
    final value = _readRequiredString(data, key);
    return _base64UrlDecode(value);
  }

  static String _base64UrlNoPad(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static List<int> _base64UrlDecode(String value) {
    final normalized = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    return base64Url.decode(normalized);
  }
}
