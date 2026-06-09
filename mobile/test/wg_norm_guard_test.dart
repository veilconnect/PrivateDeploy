import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';

void main() {
  test('normalization preserves WireGuard endpoint and full-tunnel route', () {
    final raw = buildWireguardProfileConfig(
      server: 'wg.example.com', serverPort: 51820,
      privateKey: 'PK', peerPublicKey: 'PEER',
      localAddress: ['10.0.0.20/32'], persistentKeepalive: 25,
    );
    final normalized = normalizeProfileConfigForCurrentPlatform(
      raw, targetPlatform: TargetPlatform.android);
    final cfg = jsonDecode(normalized) as Map<String, dynamic>;
    final endpoints = (cfg['endpoints'] as List).cast<Map>();
    expect(endpoints.any((e) => e['tag'] == 'wireguard-out'), isTrue,
        reason: 'endpoint must survive normalization');
    final route = cfg['route'] as Map<String, dynamic>;
    expect(route['final'], 'wireguard-out',
        reason: 'final must still route all traffic into the tunnel');
  });
}
