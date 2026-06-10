import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';

void main() {
  group('wireGuardCidrNetwork', () {
    test('derives the network address from a host CIDR', () {
      expect(wireGuardCidrNetwork('10.8.0.2/24'), '10.8.0.0/24');
      expect(wireGuardCidrNetwork('192.168.1.55/16'), '192.168.0.0/16');
      expect(wireGuardCidrNetwork('10.0.0.0/8'), '10.0.0.0/8');
      expect(wireGuardCidrNetwork('10.8.0.2'), '10.8.0.2/32');
    });

    test('rejects garbage and passes IPv6 through', () {
      expect(wireGuardCidrNetwork('not-an-ip'), isNull);
      expect(wireGuardCidrNetwork('999.1.1.1/24'), isNull);
      expect(wireGuardCidrNetwork('fd00::1/64'), 'fd00::1/64');
    });
  });

  const wg = WireGuardIntranet(
    enabled: true,
    server: 'wg.example.com',
    serverPort: 51820,
    privateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    peerPublicKey: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
    localAddress: ['10.8.0.2/24'],
    extraCidrs: ['192.168.1.0/24'],
  );

  String baseProxyConfig() => jsonEncode({
        'outbounds': [
          {
            'type': 'shadowsocks',
            'tag': 'proxy',
            'server': '203.0.113.9',
            'server_port': 8388,
            'method': 'aes-256-gcm',
            'password': 'x',
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {'protocol': 'dns', 'outbound': 'dns-out'},
            {'ip_is_private': true, 'outbound': 'direct'},
          ],
          'final': 'proxy',
        },
      });

  Map<String, dynamic> applyOverlay(WireGuardIntranet overlay) {
    final out = normalizeProfileConfigForCurrentPlatform(
      baseProxyConfig(),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: overlay),
    );
    return jsonDecode(out) as Map<String, dynamic>;
  }

  test('injects a WireGuard endpoint scoped to the LAN cidrs (not full route)',
      () {
    final cfg = applyOverlay(wg);
    final endpoints =
        (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
    final ep =
        endpoints.firstWhere((e) => e['tag'] == WireGuardIntranet.tag);
    expect(ep['type'], 'wireguard');
    final allowed =
        ((ep['peers'] as List).first as Map)['allowed_ips'] as List;
    expect(allowed, containsAll(<String>['10.8.0.0/24', '192.168.1.0/24']));
    expect(allowed, isNot(contains('0.0.0.0/0')));
  });

  test('inserts a LAN -> WireGuard rule that outranks proxy/direct, after DNS',
      () {
    final cfg = applyOverlay(wg);
    final rules =
        ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
    final wgIdx =
        rules.indexWhere((r) => r['outbound'] == WireGuardIntranet.tag);
    expect(wgIdx, greaterThanOrEqualTo(0));
    expect(rules[wgIdx]['ip_cidr'] as List,
        containsAll(<String>['10.8.0.0/24', '192.168.1.0/24']));
    final dnsIdx = rules.indexWhere((r) => r['outbound'] == 'dns-out');
    if (dnsIdx >= 0) {
      expect(dnsIdx, lessThan(wgIdx), reason: 'DNS rule must stay ahead of WG');
    }
  });

  test('proxy node outbounds coexist with the intranet tunnel', () {
    final cfg = applyOverlay(wg);
    final tags =
        (cfg['outbounds'] as List).map((o) => (o as Map)['tag']).toSet();
    expect(tags, containsAll(<String>['proxy', 'direct']));
    expect(cfg['endpoints'] as List, isNotEmpty);
  });

  test('re-applying is idempotent (single endpoint, single rule)', () {
    // Feed an output that already carries the overlay back through.
    final first = normalizeProfileConfigForCurrentPlatform(
      baseProxyConfig(),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
    );
    final second = normalizeProfileConfigForCurrentPlatform(
      first,
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
    );
    final cfg = jsonDecode(second) as Map<String, dynamic>;
    final wgEndpoints = (cfg['endpoints'] as List)
        .where((e) => (e as Map)['tag'] == WireGuardIntranet.tag)
        .length;
    final wgRules = ((cfg['route'] as Map)['rules'] as List)
        .where((r) => (r as Map)['outbound'] == WireGuardIntranet.tag)
        .length;
    expect(wgEndpoints, 1);
    expect(wgRules, 1);
  });

  test('disabled overlay is a no-op', () {
    final cfg = applyOverlay(wg.copyWith(enabled: false));
    final endpoints = (cfg['endpoints'] as List?) ?? const [];
    expect(
        endpoints.any((e) => (e as Map)['tag'] == WireGuardIntranet.tag),
        isFalse);
    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.any((r) => (r as Map)['outbound'] == WireGuardIntranet.tag),
        isFalse);
  });

  test('incomplete config does not inject even when enabled', () {
    const incomplete = WireGuardIntranet(
      enabled: true,
      server: 'wg.example.com',
      serverPort: 51820,
      // missing keys
      localAddress: ['10.8.0.2/24'],
    );
    expect(incomplete.isActive, isFalse);
    final cfg = applyOverlay(incomplete);
    final endpoints = (cfg['endpoints'] as List?) ?? const [];
    expect(
        endpoints.any((e) => (e as Map)['tag'] == WireGuardIntranet.tag),
        isFalse);
  });

  group('buildWireguardIntranetOnlyConfig (WireGuard-only tunnel)', () {
    test('carries only WireGuard for LAN, everything else direct', () {
      final out = buildWireguardIntranetOnlyConfig(
        wg,
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(out, isNotNull);
      final cfg = jsonDecode(out!) as Map<String, dynamic>;
      // WireGuard endpoint present.
      final eps = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(eps.any((e) => e['tag'] == WireGuardIntranet.tag), isTrue);
      // No proxy — only the direct outbound.
      final obTags =
          (cfg['outbounds'] as List).map((o) => (o as Map)['tag']).toSet();
      expect(obTags, equals(<dynamic>{'direct'}));
      // Default route is direct; LAN goes to WireGuard.
      final route = cfg['route'] as Map;
      expect(route['final'], 'direct');
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      final wgRule =
          rules.firstWhere((r) => r['outbound'] == WireGuardIntranet.tag);
      expect(wgRule['ip_cidr'] as List, contains('10.8.0.0/24'));
    });

    test('returns null when the overlay is inactive', () {
      expect(buildWireguardIntranetOnlyConfig(wg.copyWith(enabled: false)),
          isNull);
    });
  });
}
