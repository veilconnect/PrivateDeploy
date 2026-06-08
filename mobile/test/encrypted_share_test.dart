import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/security/encrypted_share.dart';

void main() {
  group('EncryptedShareCodec', () {
    test('round-trips encrypted proxy links', () async {
      final armored = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.proxyLinks,
        content: 'ss://example\nvless://example',
        passphrase: 'test-passphrase',
        label: 'edge-node',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      expect(EncryptedShareCodec.looksEncrypted(armored), isTrue);
      expect(armored.startsWith(armoredEncryptedSharePrefix), isTrue);

      final payload = await EncryptedShareCodec.decrypt(
        armored: armored,
        passphrase: 'test-passphrase',
      );

      expect(payload.kind, EncryptedShareKind.proxyLinks);
      expect(payload.content, 'ss://example\nvless://example');
      expect(payload.label, 'edge-node');
      expect(payload.createdAt, isNotNull);
    });

    test('rejects wrong passphrase', () async {
      final armored = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.cloudBackup,
        content: '{"provider":"vultr"}',
        passphrase: 'correct-passphrase',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );

      await expectLater(
        EncryptedShareCodec.decrypt(
          armored: armored,
          passphrase: 'wrong-passphrase',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Incorrect passphrase'),
          ),
        ),
      );
    });

    test('accepts armored content with inserted whitespace', () async {
      final armored = await EncryptedShareCodec.encrypt(
        kind: EncryptedShareKind.profileConfig,
        content: '{"outbounds":[{"type":"direct"}]}',
        passphrase: 'hello-world',
        iterations: minimumEncryptedSharePbkdf2Iterations,
      );
      final wrapped =
          '${armored.substring(0, 12)} \n ${armored.substring(12, 40)}\n${armored.substring(40)}';

      final payload = await EncryptedShareCodec.decrypt(
        armored: wrapped,
        passphrase: 'hello-world',
      );

      expect(payload.kind, EncryptedShareKind.profileConfig);
      expect(payload.content, '{"outbounds":[{"type":"direct"}]}');
    });
  });
}
