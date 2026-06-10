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

  List<Map<String, dynamic>> endpointsOf(Map<String, dynamic> decoded) =>
      ((decoded['endpoints'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> outboundsOf(Map<String, dynamic> decoded) =>
      (decoded['outbounds'] as List).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> rulesOf(Map<String, dynamic> decoded) =>
      ((decoded['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

  group('custom outbounds and rules', () {
    test(
        'converts a custom WireGuard outbound into a 1.12 endpoint and routes '
        'a CIDR to it', () {
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

      // WireGuard must land in `endpoints`, never in `outbounds` (the legacy
      // outbound form is removed in sing-box 1.12).
      final outbounds = outboundsOf(decoded);
      expect(
        outbounds.any((o) => o['type'] == 'wireguard'),
        isFalse,
        reason: 'WireGuard must not be emitted as an outbound on 1.12',
      );

      final endpoints = endpointsOf(decoded);
      final endpoint = endpoints.firstWhere(
        (e) => e['tag'] == 'home-wg',
        orElse: () => <String, dynamic>{},
      );
      expect(endpoint['type'], 'wireguard',
          reason: 'custom WireGuard must be merged as an endpoint');
      expect((endpoint['address'] as List).cast<String>(),
          contains('10.0.0.20/32'),
          reason: 'local_address maps to the endpoint address');
      expect(endpoint['private_key'], 'private-key');

      final peers = (endpoint['peers'] as List).cast<Map<String, dynamic>>();
      expect(peers, hasLength(1));
      final peer = peers.first;
      expect(peer['address'], '203.0.113.1',
          reason: 'server maps to peers[].address');
      expect(peer['port'], 51820, reason: 'server_port maps to peers[].port');
      expect(peer['public_key'], 'peer-public-key',
          reason: 'peer_public_key maps to peers[].public_key');
      expect(
          (peer['allowed_ips'] as List).cast<String>(), contains('0.0.0.0/0'));

      // The rule targeting the endpoint tag must still be generated and take
      // priority over the built-in ip_is_private -> direct rule, otherwise
      // private traffic would never reach the WireGuard tunnel.
      final rules = rulesOf(decoded);
      final wgRuleIndex = rules.indexWhere(
        (r) =>
            r['outbound'] == 'home-wg' &&
            (r['ip_cidr'] as List?)?.contains('10.0.0.0/24') == true,
      );
      expect(wgRuleIndex, greaterThanOrEqualTo(0),
          reason: '10.0.0.0/24 should be routed to the WireGuard endpoint');
      final privateRuleIndex = rules.indexWhere(
        (r) => r['ip_is_private'] == true && r['outbound'] == 'direct',
      );
      if (privateRuleIndex >= 0) {
        expect(wgRuleIndex, lessThan(privateRuleIndex),
            reason: 'custom rule should be ordered before ip_is_private');
      }
    });

    test('places persistent_keepalive_interval and mtu correctly', () {
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
            'pre_shared_key': 'pre-shared-key',
            'mtu': 1408,
            // A user pasting a standard WireGuard JSON commonly includes this.
            // On 1.12 it must live inside the peer, not at the top level (where
            // sing-box would reject the whole config as an unknown field).
            'persistent_keepalive_interval': 25,
          },
        ],
      );

      final decoded = normalize(settings);
      final endpoint = endpointsOf(decoded).firstWhere(
        (e) => e['tag'] == 'home-wg',
      );

      expect(endpoint.containsKey('persistent_keepalive_interval'), isFalse,
          reason: 'keepalive must not sit at the endpoint top level');
      expect(endpoint['mtu'], 1408, reason: 'mtu maps to the endpoint level');

      final peer =
          (endpoint['peers'] as List).cast<Map<String, dynamic>>().first;
      expect(peer['persistent_keepalive_interval'], 25,
          reason: 'keepalive must be nested inside the peer');
      expect(peer['pre_shared_key'], 'pre-shared-key',
          reason: 'pre_shared_key maps into the peer');
    });

    test('re-normalizing an already-converted config is idempotent', () {
      final wg = buildWireguardOutbound(
        tag: 'home-wg',
        server: '203.0.113.1',
        serverPort: 51820,
        privateKey: 'private-key',
        peerPublicKey: 'peer-public-key',
        localAddress: const ['10.0.0.20/32'],
      );
      final settings = VpnRoutingSettings(customOutbounds: [wg]);

      final once = normalize(settings);
      // Feed the already-normalized config back through with the same settings.
      final twice = jsonDecode(
        normalizeProfileConfigForCurrentPlatform(
          jsonEncode(once),
          targetPlatform: TargetPlatform.android,
          routingSettings: settings,
        ),
      ) as Map<String, dynamic>;

      final homeWgEndpoints =
          endpointsOf(twice).where((e) => e['tag'] == 'home-wg').toList();
      expect(homeWgEndpoints, hasLength(1),
          reason: 're-normalizing must not append a duplicate endpoint');
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
      final rules = rulesOf(decoded);
      expect(rules.any((r) => r['outbound'] == 'missing-tag'), isFalse);
    });

    test('skips a custom WireGuard outbound whose tag collides with direct',
        () {
      final settings = VpnRoutingSettings(
        customOutbounds: [
          <String, dynamic>{'type': 'wireguard', 'tag': 'direct'},
        ],
      );
      final decoded = normalize(settings);

      final directOutbounds =
          outboundsOf(decoded).where((o) => o['tag'] == 'direct').toList();
      expect(directOutbounds.length, 1,
          reason: 'tag collision must not duplicate the direct outbound');
      expect(directOutbounds.first['type'], 'direct',
          reason: 'the original direct outbound must be preserved');
      expect(endpointsOf(decoded).any((e) => e['tag'] == 'direct'), isFalse,
          reason: 'the colliding WireGuard endpoint must not be created');
    });
  });
}
