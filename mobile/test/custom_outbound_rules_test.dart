import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> normalize(VpnRoutingSettings settings) {
    final baseConfig = jsonEncode({
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {'final': 'direct', 'rules': <dynamic>[]},
    });
    final result = normalizeProfileConfigForCurrentPlatform(
      baseConfig,
      targetPlatform: TargetPlatform.android,
      routingSettings: settings,
    );
    return jsonDecode(result) as Map<String, dynamic>;
  }

  group('custom outbounds and rules', () {
    test('merges a custom WireGuard outbound and routes a CIDR to it', () {
      final wg = buildWireguardOutbound(
        tag: 'home-wg',
        server: '203.0.113.1',
        serverPort: 51820,
        privateKey: 'private-key',
        peerPublicKey: 'peer-public-key',
        localAddress: const ['10.0.0.20/32'],
      );
      final settings = VpnRoutingSettings(
        customOutbounds: [wg],
        customRules: const [
          CustomRoutingRule(
            matcher: CustomRuleMatcher.ipCidr,
            value: '10.0.0.0/24',
            outbound: 'home-wg',
          ),
        ],
      );

      final decoded = normalize(settings);

      final outbounds =
          (decoded['outbounds'] as List).cast<Map<String, dynamic>>();
      expect(
        outbounds.any(
          (o) => o['tag'] == 'home-wg' && o['type'] == 'wireguard',
        ),
        isTrue,
        reason: 'custom WireGuard outbound should be merged into outbounds',
      );

      final rules = ((decoded['route'] as Map)['rules'] as List)
          .cast<Map<String, dynamic>>();
      final wgRuleIndex = rules.indexWhere(
        (r) =>
            r['outbound'] == 'home-wg' &&
            (r['ip_cidr'] as List?)?.contains('10.0.0.0/24') == true,
      );
      expect(wgRuleIndex, greaterThanOrEqualTo(0),
          reason: '10.0.0.0/24 should be routed to home-wg');

      // The custom rule must take priority over the built-in
      // ip_is_private -> direct rule, otherwise private traffic would never
      // reach the WireGuard tunnel.
      final privateRuleIndex = rules.indexWhere(
        (r) => r['ip_is_private'] == true && r['outbound'] == 'direct',
      );
      if (privateRuleIndex >= 0) {
        expect(wgRuleIndex, lessThan(privateRuleIndex),
            reason: 'custom rule should be ordered before ip_is_private');
      }
    });

    test('drops rules whose target outbound does not exist', () {
      const settings = VpnRoutingSettings(
        customRules: [
          CustomRoutingRule(
            matcher: CustomRuleMatcher.ipCidr,
            value: '10.0.0.0/24',
            outbound: 'missing-tag',
          ),
        ],
      );
      final decoded = normalize(settings);
      final rules = ((decoded['route'] as Map)['rules'] as List)
          .cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['outbound'] == 'missing-tag'), isFalse);
    });

    test('skips a custom outbound whose tag collides with an existing one', () {
      final settings = VpnRoutingSettings(
        customOutbounds: [
          <String, dynamic>{'type': 'wireguard', 'tag': 'direct'},
        ],
      );
      final decoded = normalize(settings);
      final outbounds =
          (decoded['outbounds'] as List).cast<Map<String, dynamic>>();
      final directOutbounds =
          outbounds.where((o) => o['tag'] == 'direct').toList();
      expect(directOutbounds.length, 1,
          reason: 'tag collision must not duplicate the direct outbound');
      expect(directOutbounds.first['type'], 'direct',
          reason: 'the original direct outbound must be preserved');
    });

    test(
        'strips persistent_keepalive_interval from a WireGuard outbound '
        '(unsupported by bundled sing-box v1.11 → would reject whole config)',
        () {
      final settings = VpnRoutingSettings(
        customOutbounds: [
          <String, dynamic>{
            'type': 'wireguard',
            'tag': 'home-wg',
            'server': '203.0.113.1',
            'server_port': 51820,
            'local_address': const ['10.0.0.20/32'],
            'private_key': 'private-key',
            'peer_public_key': 'peer-public-key',
            // A user pasting a standard WireGuard JSON commonly includes this;
            // it must be stripped, not passed through.
            'persistent_keepalive_interval': 25,
          },
        ],
      );
      final decoded = normalize(settings);
      final wg = (decoded['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == 'home-wg');
      expect(wg.containsKey('persistent_keepalive_interval'), isFalse,
          reason: 'invalid field must be stripped so sing-box accepts config');
      expect(wg['server'], '203.0.113.1',
          reason: 'the rest of the WireGuard outbound must be preserved');
    });
  });
}
