import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_provider.dart';
import 'package:privatedeploy_mobile/features/vpn/vpn_status_messages.dart';
import 'package:privatedeploy_mobile/l10n/app_localizations.dart';

Future<AppLocalizations> _l10nFor(String locale) {
  return AppLocalizations.delegate.load(Locale(locale));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('localizeVpnStatusMessage', () {
    test('routes UpstreamDegraded canonical message to localized en text',
        () async {
      final l10n = await _l10nFor('en');
      final out = localizeVpnStatusMessage(
        VpnProvider.tunnelUpstreamDegradedMessage,
        l10n,
      );
      expect(out, equals(l10n.tunnelUpstreamDegradedMessageLocalized));
      expect(out, contains('Wi-Fi'));
    });

    test('routes UpstreamDegraded canonical message to localized zh text',
        () async {
      final l10n = await _l10nFor('zh');
      final out = localizeVpnStatusMessage(
        VpnProvider.tunnelUpstreamDegradedMessage,
        l10n,
      );
      expect(out, equals(l10n.tunnelUpstreamDegradedMessageLocalized));
      expect(out, contains('Wi-Fi'));
      // Distinctly-Chinese token from the localized guidance, confirming zh
      // routing (not the en string). The cellular-specific '蜂窝' wording was
      // intentionally generalized to "current network" in the public-release
      // copy pass (commit 718ca5fa).
      expect(out, contains('更换其他节点'));
    });

    test('passes unknown messages through unchanged', () async {
      final l10n = await _l10nFor('en');
      const unknown = 'sing-box: outbound dial timeout';
      expect(localizeVpnStatusMessage(unknown, l10n), equals(unknown));
    });

    test('returns empty string for null input', () async {
      final l10n = await _l10nFor('en');
      expect(localizeVpnStatusMessage(null, l10n), isEmpty);
    });
  });
}
