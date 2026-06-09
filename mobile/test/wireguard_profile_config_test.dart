import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';

void main() {
  group('buildWireguardProfileConfig', () {
    Map<String, dynamic> build({int keepalive = 25}) {
      final json = buildWireguardProfileConfig(
        server: 'wg.example.com',
        serverPort: 51820,
        privateKey: 'PRIVATE_KEY_BASE64',
        peerPublicKey: 'PEER_PUBLIC_KEY_BASE64',
        localAddress: ['10.0.0.20/32', 'fd00::20/128'],
        preSharedKey: 'PSK_BASE64',
        mtu: 1408,
        persistentKeepalive: keepalive,
      );
      return jsonDecode(json) as Map<String, dynamic>;
    }

    test('emits a sing-box 1.12 wireguard endpoint, not a legacy outbound', () {
      final config = build();
      final endpoints = config['endpoints'] as List;
      expect(endpoints, hasLength(1));
      final endpoint = endpoints.single as Map<String, dynamic>;
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['tag'], 'wireguard-out');
      expect(endpoint['private_key'], 'PRIVATE_KEY_BASE64');
      expect(endpoint['mtu'], 1408);
      expect(endpoint['address'], ['10.0.0.20/32', 'fd00::20/128']);

      // The legacy wireguard *outbound* form must not appear — 1.12 rejects it.
      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(
        outbounds.any((o) => o['type'] == 'wireguard'),
        isFalse,
        reason: 'WireGuard must live under endpoints[], not outbounds[]',
      );
    });

    test('nests peer fields and a keepalive to prevent NAT-timeout drops', () {
      final config = build();
      final endpoint =
          (config['endpoints'] as List).single as Map<String, dynamic>;
      final peer = (endpoint['peers'] as List).single as Map<String, dynamic>;
      expect(peer['address'], 'wg.example.com');
      expect(peer['port'], 51820);
      expect(peer['public_key'], 'PEER_PUBLIC_KEY_BASE64');
      expect(peer['pre_shared_key'], 'PSK_BASE64');
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
      expect(peer['persistent_keepalive_interval'], 25);
    });

    test('routes all traffic through the tunnel (full-tunnel VPN)', () {
      final config = build();
      final route = config['route'] as Map<String, dynamic>;
      expect(route['final'], 'wireguard-out');
      expect(route['auto_detect_interface'], isTrue);
      expect(route['default_network_strategy'], 'default');

      // A tun inbound + a direct outbound are required for a connectable
      // Android profile; the normalizer would inject a tun otherwise, but we
      // ship a complete config so validation passes immediately.
      final inbounds = (config['inbounds'] as List).cast<Map>();
      expect(inbounds.any((i) => i['type'] == 'tun'), isTrue);
      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(outbounds.any((o) => o['type'] == 'direct'), isTrue);
    });

    test('omits the keepalive when explicitly disabled', () {
      final config = build(keepalive: 0);
      final endpoint =
          (config['endpoints'] as List).single as Map<String, dynamic>;
      final peer = (endpoint['peers'] as List).single as Map<String, dynamic>;
      expect(peer.containsKey('persistent_keepalive_interval'), isFalse);
    });
  });
}
