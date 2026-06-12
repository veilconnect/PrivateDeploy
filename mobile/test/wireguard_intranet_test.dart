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
    final endpoints = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
    final ep = endpoints.firstWhere((e) => e['tag'] == WireGuardIntranet.tag);
    expect(ep['type'], 'wireguard');
    final allowed = ((ep['peers'] as List).first as Map)['allowed_ips'] as List;
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
    expect(endpoints.any((e) => (e as Map)['tag'] == WireGuardIntranet.tag),
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
    expect(endpoints.any((e) => (e as Map)['tag'] == WireGuardIntranet.tag),
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

  group('duplicate-keypair collapse (the instability root cause)', () {
    // A custom-outbound WireGuard dialing the same server with the SAME private
    // key as the intranet overlay. Two endpoints sharing one keypair make the
    // WG server steal the session back and forth -> constant drops.
    Map<String, dynamic> sameKeyCustomWg() => {
          'type': 'wireguard',
          'tag': 'home-wg',
          'server': 'wg.example.com',
          'server_port': 51820,
          'local_address': ['10.8.0.2/24'],
          'private_key': wg.privateKey, // <-- identical keypair
          'peer_public_key': wg.peerPublicKey,
        };

    test('overlay drops a same-key endpoint and its orphaned route rule', () {
      final out = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [sameKeyCustomWg()],
          customRules: const [
            CustomRoutingRule(
              matcher: CustomRuleMatcher.ipCidr,
              value: '10.0.0.0/24',
              outbound: 'home-wg',
            ),
          ],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final endpoints = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      // Exactly one WG endpoint survives — the intranet overlay.
      expect(endpoints, hasLength(1));
      expect(endpoints.single['tag'], WireGuardIntranet.tag);
      // The orphaned `... -> home-wg` rule is gone (a rule pointing at a
      // removed outbound makes sing-box reject the whole config)...
      final rules =
          ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['outbound'] == 'home-wg'), isFalse);
      // ...but its routed CIDR (10.0.0.0/24, wider than the auto-derived WG
      // subnet) is FOLDED into the overlay so coverage isn't silently lost.
      final wgRule =
          rules.firstWhere((r) => r['outbound'] == WireGuardIntranet.tag);
      expect(wgRule['ip_cidr'] as List, contains('10.0.0.0/24'));
      final allowed = ((endpoints.single['peers'] as List).first
          as Map)['allowed_ips'] as List;
      expect(allowed, contains('10.0.0.0/24'));
    });

    test('a superseded domain_suffix rule is retargeted, not dropped', () {
      // Collapsing the same-key home-wg must not silently lose a
      // `domain_suffix internal.corp -> home-wg` rule; it should be re-pointed
      // at the surviving overlay endpoint.
      final out = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [sameKeyCustomWg()],
          customRules: const [
            CustomRoutingRule(
              matcher: CustomRuleMatcher.domainSuffix,
              value: 'internal.corp',
              outbound: 'home-wg',
            ),
          ],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final rules =
          ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['outbound'] == 'home-wg'), isFalse);
      final domainRule = rules.firstWhere(
        (r) => (r['domain_suffix'] as List?)?.contains('internal.corp') == true,
        orElse: () => <String, dynamic>{},
      );
      expect(domainRule['outbound'], WireGuardIntranet.tag,
          reason: 'domain rule must be retargeted to the overlay, not dropped');
    });

    test(
        'a constrained superseded rule (ip_cidr+port) is retargeted, NOT widened',
        () {
      // Base config already carries a constrained `10.99.0.0/16 + port 443 ->
      // home-wg` rule. Collapsing home-wg must keep that exact constraint (just
      // retargeted) and must NOT fold 10.99.0.0/16 into the broad all-ports rule.
      final base = jsonDecode(baseProxyConfig()) as Map<String, dynamic>;
      (base['route'] as Map)['rules'] = [
        ...((base['route'] as Map)['rules'] as List),
        {
          'ip_cidr': ['10.99.0.0/16'],
          'port': [443],
          'outbound': 'home-wg',
        },
      ];
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(base),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [sameKeyCustomWg()],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final rules =
          ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      // The broad overlay rule must NOT carry the constrained CIDR.
      final broad = rules.firstWhere(
          (r) => r['outbound'] == WireGuardIntranet.tag && r['port'] == null);
      expect(broad['ip_cidr'] as List, isNot(contains('10.99.0.0/16')));
      // The constrained rule survives, retargeted, with its port intact.
      final constrained = rules.firstWhere(
        (r) =>
            r['outbound'] == WireGuardIntranet.tag &&
            (r['ip_cidr'] as List?)?.contains('10.99.0.0/16') == true,
        orElse: () => <String, dynamic>{},
      );
      expect(constrained['port'], [443]);
      // But the peer must still ACCEPT that range (allowed_ips), or WG drops it.
      final ep = (cfg['endpoints'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((e) => e['tag'] == WireGuardIntranet.tag);
      final allowed =
          ((ep['peers'] as List).first as Map)['allowed_ips'] as List;
      expect(allowed, contains('10.99.0.0/16'));
    });

    test('overlay + same-key custom WG + custom rule is byte-idempotent', () {
      // normalize(normalize(x)) == normalize(x): re-normalizing the output with
      // the SAME routing settings (which re-add the custom WG every pass) must
      // not lose folded CIDRs or accumulate rules.
      final settings = VpnRoutingSettings(
        wireGuardIntranet: wg,
        customOutbounds: [sameKeyCustomWg()],
        customRules: const [
          CustomRoutingRule(
            matcher: CustomRuleMatcher.ipCidr,
            value: '10.0.0.0/24',
            outbound: 'home-wg',
          ),
        ],
      );
      final out1 = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: settings,
      );
      final out2 = normalizeProfileConfigForCurrentPlatform(
        out1,
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: settings,
      );
      expect(out2, out1, reason: 'pipeline must be idempotent');
      // And the folded custom CIDR survives the second pass.
      final cfg2 = jsonDecode(out2) as Map<String, dynamic>;
      final wgRule = ((cfg2['route'] as Map)['rules'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((r) =>
              r['outbound'] == WireGuardIntranet.tag && r['port'] == null);
      expect(wgRule['ip_cidr'] as List, contains('10.0.0.0/24'));
    });

    test('a DIFFERENT-key custom WG is left intact (only same key collapses)',
        () {
      final differentKey = sameKeyCustomWg()
        ..['private_key'] = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=';
      final out = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [differentKey],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, containsAll(<String>['home-wg', WireGuardIntranet.tag]));
    });

    test('a same-key custom WG on a DIFFERENT server is NOT collapsed', () {
      // Reusing the client key against another server is not a session-steal
      // conflict — each server keeps its own session. Must be left intact.
      final otherServer = sameKeyCustomWg()..['server'] = 'other.example.com';
      final out = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [otherServer],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, containsAll(<String>['home-wg', WireGuardIntranet.tag]));
    });

    test('a same-key custom WG with a DIFFERENT peer key is NOT collapsed', () {
      // Same client key + endpoint address can still describe a different peer
      // if the server rotates or multiplexes peer identities. Do not reuse or
      // delete that endpoint as if it were the intranet peer.
      final otherPeer = sameKeyCustomWg()
        ..['peer_public_key'] = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=';
      final out = normalizeProfileConfigForCurrentPlatform(
        baseProxyConfig(),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg,
          customOutbounds: [otherPeer],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, containsAll(<String>['home-wg', WireGuardIntranet.tag]));
    });

    test('overlay is SKIPPED when a same-key WG node is the primary tunnel',
        () {
      // A full-tunnel `wireguard-out` profile (route.final = wireguard-out)
      // already carries this peer. Deleting it would dangle route.final; adding
      // a second same-key endpoint would reintroduce the session-steal. So the
      // overlay must no-op and leave the full tunnel untouched.
      final fullTunnel = buildWireguardProfileConfig(
        server: 'wg.example.com',
        serverPort: 51820,
        privateKey: wg.privateKey,
        peerPublicKey: wg.peerPublicKey,
        localAddress: const ['10.8.0.2/24'],
      );
      final out = normalizeProfileConfigForCurrentPlatform(
        fullTunnel,
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, contains('wireguard-out'));
      expect(tags, isNot(contains(WireGuardIntranet.tag)));
      expect((cfg['route'] as Map)['final'], 'wireguard-out');
    });
  });

  group('standalone duplicate collapse (overlay-independent)', () {
    Map<String, dynamic> twoEndpointBase({int? portA, int? portB}) => {
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
          'endpoints': [
            {
              'type': 'wireguard',
              'tag': 'wg-a',
              'private_key': wg.privateKey,
              'peers': [
                {
                  'address': 'wg.example.com',
                  if (portA != null) 'port': portA,
                  'public_key': wg.peerPublicKey,
                },
              ],
            },
            {
              'type': 'wireguard',
              'tag': 'wg-b',
              'private_key': wg.privateKey,
              'peers': [
                {
                  'address': 'wg.example.com',
                  if (portB != null) 'port': portB,
                  'public_key': wg.peerPublicKey,
                },
              ],
            },
          ],
          'route': {
            'rules': [
              {'ip_is_private': true, 'outbound': 'direct'},
            ],
            'final': 'wg-a',
          },
        };

    test('collapses when one peer omits the port (missing port = wildcard)',
        () {
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(twoEndpointBase(portA: 51820 /* portB omitted */)),
        targetPlatform: TargetPlatform.fuchsia,
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, equals(<dynamic>['wg-a']),
          reason: 'same key+server, port-less paste must still collapse');
    });

    test('does NOT collapse two DIFFERENT explicit ports (distinct peers)', () {
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(twoEndpointBase(portA: 51820, portB: 51821)),
        targetPlatform: TargetPlatform.fuchsia,
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, containsAll(<String>['wg-a', 'wg-b']));
    });

    test('does NOT collapse two DIFFERENT peer public keys', () {
      final base = twoEndpointBase(portA: 51820, portB: 51820);
      ((((base['endpoints'] as List)[1] as Map)['peers'] as List).first
              as Map)['public_key'] =
          'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=';
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(base),
        targetPlatform: TargetPlatform.fuchsia,
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, containsAll(<String>['wg-a', 'wg-b']));
    });

    test('two same-peer endpoints collapse even when the overlay is OFF', () {
      // A full-tunnel wireguard-out node (route.final) + a same-key custom
      // outbound. With the intranet overlay DISABLED, the standalone pass must
      // still collapse them to one endpoint and retarget the custom rule.
      final base = jsonDecode(buildWireguardProfileConfig(
        server: 'wg.example.com',
        serverPort: 51820,
        privateKey: wg.privateKey,
        peerPublicKey: wg.peerPublicKey,
        localAddress: const ['10.8.0.2/24'],
      )) as Map<String, dynamic>;
      (base['route'] as Map)['rules'] = [
        {
          'ip_cidr': ['10.0.0.0/24'],
          'outbound': 'home-wg'
        },
      ];
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(base),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          // overlay OFF (defaults)
          customOutbounds: [
            {
              'type': 'wireguard',
              'tag': 'home-wg',
              'server': 'wg.example.com',
              'server_port': 51820,
              'local_address': ['10.8.0.2/24'],
              'private_key': wg.privateKey,
              'peer_public_key': wg.peerPublicKey,
            },
          ],
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      // Only the route.final survivor (wireguard-out) remains.
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toSet();
      expect(tags, equals(<dynamic>{'wireguard-out'}));
      // The home-wg rule is retargeted to the survivor — no dangling tag.
      final rules =
          ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r['outbound'] == 'home-wg'), isFalse);
      expect((cfg['route'] as Map)['final'], 'wireguard-out');
    });
  });

  test('selector-member same-peer WG: overlay routes LAN to it (no duplicate)',
      () {
    // home-wg sits in the proxy selector pool with route.final = "select".
    // The overlay must NOT add a second same-key endpoint; it routes the LAN
    // CIDRs to the existing home-wg so intranet traffic actually flows through
    // WireGuard.
    final base = jsonDecode(baseProxyConfig()) as Map<String, dynamic>;
    base['outbounds'] = [
      ...(base['outbounds'] as List),
      {
        'type': 'selector',
        'tag': 'select',
        'outbounds': ['proxy', 'home-wg'],
        'default': 'proxy',
      },
    ];
    (base['route'] as Map)['final'] = 'select';
    final out = normalizeProfileConfigForCurrentPlatform(
      jsonEncode(base),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(
        wireGuardIntranet: wg,
        customOutbounds: [
          {
            'type': 'wireguard',
            'tag': 'home-wg',
            'server': 'wg.example.com',
            'server_port': 51820,
            'local_address': ['10.8.0.2/24'],
            'private_key': wg.privateKey,
            'peer_public_key': wg.peerPublicKey,
          },
        ],
      ),
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    // No second same-key endpoint was created.
    final wgTags =
        (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toList();
    expect(wgTags, contains('home-wg'));
    expect(wgTags, isNot(contains(WireGuardIntranet.tag)));
    // LAN routes to the existing home-wg endpoint.
    final rules =
        ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
    final lanRule = rules.firstWhere(
      (r) => r['outbound'] == 'home-wg' && r['ip_cidr'] != null,
      orElse: () => <String, dynamic>{},
    );
    expect(lanRule['ip_cidr'] as List?, contains('10.8.0.0/24'));

    // Idempotent: re-normalizing must not stack a second LAN -> home-wg rule.
    final out2 = normalizeProfileConfigForCurrentPlatform(
      out,
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
    );
    final cfg2 = jsonDecode(out2) as Map<String, dynamic>;
    final lanRules = ((cfg2['route'] as Map)['rules'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) =>
            r['outbound'] == 'home-wg' &&
            (r['ip_cidr'] as List?)?.contains('10.8.0.0/24') == true)
        .length;
    expect(lanRules, 1, reason: 'reuse rule must not accumulate per pass');
  });

  test('overlay clamps an oversized TUN MTU to 1408 (avoids WG-path stall)',
      () {
    final base = jsonDecode(baseProxyConfig()) as Map<String, dynamic>;
    base['inbounds'] = [
      {
        'type': 'tun',
        'tag': 'tun-in',
        'mtu': 9000, // sing-box default when omitted
        'auto_route': true,
      },
    ];
    final out = normalizeProfileConfigForCurrentPlatform(
      jsonEncode(base),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    final tun = (cfg['inbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((i) => i['type'] == 'tun');
    expect(tun['mtu'], 1408);
  });

  test('overlay leaves an already-small TUN MTU alone', () {
    final base = jsonDecode(baseProxyConfig()) as Map<String, dynamic>;
    base['inbounds'] = [
      {'type': 'tun', 'tag': 'tun-in', 'mtu': 1280, 'auto_route': true},
    ];
    final out = normalizeProfileConfigForCurrentPlatform(
      jsonEncode(base),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    final tun = (cfg['inbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((i) => i['type'] == 'tun');
    expect(tun['mtu'], 1280);
  });

  test('overlay keepalive of 0 is an explicit opt-out (no NAT refresh)', () {
    final cfg = applyOverlay(wg.copyWith(persistentKeepalive: 0));
    final ep = (cfg['endpoints'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['tag'] == WireGuardIntranet.tag);
    final peer = (ep['peers'] as List).first as Map;
    expect(peer.containsKey('persistent_keepalive_interval'), isFalse);
  });

  test('overlay defaults keepalive to 25 (NAT stays alive)', () {
    final cfg = applyOverlay(wg); // wg.persistentKeepalive == 25
    final ep = (cfg['endpoints'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['tag'] == WireGuardIntranet.tag);
    final peer = (ep['peers'] as List).first as Map;
    expect(peer['persistent_keepalive_interval'], 25);
  });

  test('custom-outbound WireGuard with no keepalive defaults to 25s', () {
    // The classic "connects then drops on idle": a pasted WG outbound without
    // persistent_keepalive_interval must still get the wg-quick default.
    final out = normalizeProfileConfigForCurrentPlatform(
      baseProxyConfig(),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(
        // Intranet overlay disabled so only the custom WG endpoint exists.
        customOutbounds: [
          {
            'type': 'wireguard',
            'tag': 'home-wg',
            'server': 'wg.example.com',
            'server_port': 51820,
            'local_address': ['10.8.0.2/24'],
            'private_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'peer_public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
            // no persistent_keepalive_interval
          },
        ],
      ),
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    final ep = (cfg['endpoints'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['tag'] == 'home-wg');
    final peer = (ep['peers'] as List).first as Map;
    expect(peer['persistent_keepalive_interval'], 25);
  });

  test('an explicit keepalive of 0 opts out (no NAT refresh)', () {
    final out = normalizeProfileConfigForCurrentPlatform(
      baseProxyConfig(),
      targetPlatform: TargetPlatform.fuchsia,
      routingSettings: VpnRoutingSettings(
        customOutbounds: [
          {
            'type': 'wireguard',
            'tag': 'home-wg',
            'server': 'wg.example.com',
            'server_port': 51820,
            'local_address': ['10.8.0.2/24'],
            'private_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'peer_public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
            'persistent_keepalive_interval': 0,
          },
        ],
      ),
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    final ep = (cfg['endpoints'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['tag'] == 'home-wg');
    final peer = (ep['peers'] as List).first as Map;
    expect(peer.containsKey('persistent_keepalive_interval'), isFalse);
  });

  test('reserved tags now include the managed WireGuard tunnels', () {
    expect(validateVpnRoutingOutboundTag('wireguard-intranet'), isNotNull);
    expect(validateVpnRoutingOutboundTag('wireguard-out'), isNotNull);
    expect(validateVpnRoutingOutboundTag('home-wg'), isNull);
  });

  group('TUN MTU clamp covers EVERY config carrying a WG endpoint', () {
    // A full-tunnel WG profile saved by a previous app version: endpoints[]
    // format but NO tun.mtu (sing-box defaults it to 9000 — the stall bug).
    Map<String, dynamic> legacyFullTunnelWg({int? endpointMtu, int? tunMtu}) =>
        {
          'inbounds': [
            {
              'type': 'tun',
              'tag': 'tun-in',
              if (tunMtu != null) 'mtu': tunMtu,
              'auto_route': true,
            },
          ],
          'endpoints': [
            {
              'type': 'wireguard',
              'tag': 'wireguard-out',
              'private_key': wg.privateKey,
              if (endpointMtu != null) 'mtu': endpointMtu,
              'local_address': ['10.8.0.2/24'],
              'peers': [
                {
                  'address': 'wg.example.com',
                  'port': 51820,
                  'public_key': wg.peerPublicKey,
                  'allowed_ips': ['0.0.0.0/0'],
                },
              ],
            },
          ],
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {'final': 'wireguard-out'},
        };

    Map<String, dynamic> tunOf(String out) =>
        ((jsonDecode(out) as Map<String, dynamic>)['inbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((i) => i['type'] == 'tun');

    test('legacy full-tunnel WG profile is clamped to 1408 (overlay OFF)', () {
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(legacyFullTunnelWg()),
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(tunOf(out)['mtu'], 1408);
    });

    test('clamp still lands on the overlay same-peer-final early-return path',
        () {
      // route.final IS the same WG peer -> the overlay skips entirely, but
      // the clamp must still reach the tun.
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(legacyFullTunnelWg()),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(wireGuardIntranet: wg),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final tags =
          (cfg['endpoints'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, isNot(contains(WireGuardIntranet.tag)),
          reason: 'overlay must still skip the same-peer full tunnel');
      expect(tunOf(out)['mtu'], 1408);
    });

    test('a LOWER explicit endpoint MTU pulls the TUN down with it', () {
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(legacyFullTunnelWg(endpointMtu: 1280)),
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(tunOf(out)['mtu'], 1280);
    });

    test('an already-smaller TUN MTU is left alone', () {
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(legacyFullTunnelWg(tunMtu: 1200)),
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(tunOf(out)['mtu'], 1200);
    });

    test('clamping is byte-idempotent', () {
      final first = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(legacyFullTunnelWg()),
        targetPlatform: TargetPlatform.fuchsia,
      );
      final second = normalizeProfileConfigForCurrentPlatform(
        first,
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(second, first);
    });

    test('full-tunnel builder honors a user MTU below 1408', () {
      final out = buildWireguardProfileConfig(
        server: 'wg.example.com',
        serverPort: 51820,
        privateKey: wg.privateKey,
        peerPublicKey: wg.peerPublicKey,
        localAddress: const ['10.8.0.2/24'],
        mtu: 1280,
      );
      expect(tunOf(out)['mtu'], 1280);
    });

    test('WG-only builder honors a user MTU below 1408', () {
      final out = buildWireguardIntranetOnlyConfig(
        wg.copyWith(mtu: 1280),
        targetPlatform: TargetPlatform.fuchsia,
      );
      expect(out, isNotNull);
      expect(tunOf(out!)['mtu'], 1280);
    });
  });

  group('invalid WG addresses fail loudly (no silent direct-only tunnel)', () {
    test('WG-only builder returns null when no address yields a routable CIDR',
        () {
      final bad = wg.copyWith(
        localAddress: ['999.1.1.1/24'], // passes the old non-empty check only
        extraCidrs: const [],
      );
      expect(bad.isActive, isTrue,
          reason: 'legacy weak isConfigured accepts it — builder must not');
      expect(bad.intranetCidrs, isEmpty);
      expect(
        buildWireguardIntranetOnlyConfig(
          bad,
          targetPlatform: TargetPlatform.fuchsia,
        ),
        isNull,
      );
    });

    test('wireGuardCidrNetwork validates IPv6 addresses and prefixes', () {
      expect(wireGuardCidrNetwork('fd00::1'), 'fd00::1/128');
      expect(wireGuardCidrNetwork('fd00::/64'), 'fd00::/64');
      expect(wireGuardCidrNetwork('fd00::zz/64'), isNull);
      expect(wireGuardCidrNetwork('fd00::1/200'), isNull);
    });
  });

  group('allowed_ips merge is per address family', () {
    test('reused full-IPv4-route peer still unions IPv6 LAN CIDRs', () {
      // home-wg is referenced (selector member) with allowed_ips 0.0.0.0/0:
      // full IPv4 route. The overlay adds an IPv6 LAN CIDR — it must be
      // unioned (the IPv4 full route does NOT cover IPv6), or the route rule
      // sends fd00::/64 to the peer and WireGuard silently drops it.
      final base = jsonDecode(baseProxyConfig()) as Map<String, dynamic>;
      base['endpoints'] = [
        {
          'type': 'wireguard',
          'tag': 'home-wg',
          'private_key': wg.privateKey,
          'local_address': ['10.8.0.2/24'],
          'peers': [
            {
              'address': 'wg.example.com',
              'port': 51820,
              'public_key': wg.peerPublicKey,
              'allowed_ips': ['0.0.0.0/0'],
            },
          ],
        },
      ];
      base['outbounds'] = [
        ...(base['outbounds'] as List),
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': ['proxy', 'home-wg'],
          'default': 'proxy',
        },
      ];
      (base['route'] as Map)['final'] = 'select';
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(base),
        targetPlatform: TargetPlatform.fuchsia,
        routingSettings: VpnRoutingSettings(
          wireGuardIntranet: wg.copyWith(extraCidrs: ['fd00::/64']),
        ),
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final ep = (cfg['endpoints'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((e) => e['tag'] == 'home-wg');
      final allowed =
          (((ep['peers'] as List).first as Map)['allowed_ips'] as List)
              .cast<String>();
      expect(allowed, contains('0.0.0.0/0'));
      expect(allowed, contains('fd00::/64'));
      expect(allowed, isNot(contains('10.8.0.0/24')),
          reason: 'IPv4 LAN is already covered by the IPv4 full route');
    });

    test(
        'duplicate collapse unions IPv6 allowed_ips into an IPv4-full-route '
        'survivor', () {
      final config = {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'endpoints': [
          {
            'type': 'wireguard',
            'tag': 'wg-a',
            'private_key': wg.privateKey,
            'peers': [
              {
                'address': 'wg.example.com',
                'port': 51820,
                'public_key': wg.peerPublicKey,
                'allowed_ips': ['0.0.0.0/0'],
              },
            ],
          },
          {
            'type': 'wireguard',
            'tag': 'wg-b',
            'private_key': wg.privateKey,
            'peers': [
              {
                'address': 'wg.example.com',
                'port': 51820,
                'public_key': wg.peerPublicKey,
                'allowed_ips': ['fd00::/64'],
              },
            ],
          },
        ],
        'route': {
          'rules': <Map<String, dynamic>>[],
          'final': 'wg-a',
        },
      };
      final out = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(config),
        targetPlatform: TargetPlatform.fuchsia,
      );
      final cfg = jsonDecode(out) as Map<String, dynamic>;
      final eps = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(eps.map((e) => e['tag']), equals(<dynamic>['wg-a']));
      final allowed =
          (((eps.first['peers'] as List).first as Map)['allowed_ips'] as List)
              .cast<String>();
      expect(allowed, containsAll(<String>['0.0.0.0/0', 'fd00::/64']));
    });
  });

  test('collapsing a duplicate retargets endpoints[].detour onto the survivor',
      () {
    final config = {
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'endpoints': [
        {
          'type': 'wireguard',
          'tag': 'wg-a',
          'private_key': wg.privateKey,
          'peers': [
            {
              'address': 'wg.example.com',
              'port': 51820,
              'public_key': wg.peerPublicKey,
            },
          ],
        },
        {
          'type': 'wireguard',
          'tag': 'wg-b',
          'private_key': wg.privateKey,
          'peers': [
            {
              'address': 'wg.example.com',
              'port': 51820,
              'public_key': wg.peerPublicKey,
            },
          ],
        },
        // A different peer dialing THROUGH the duplicate: its detour must be
        // rewritten to the survivor, or sing-box rejects the whole config.
        {
          'type': 'wireguard',
          'tag': 'other-wg',
          'detour': 'wg-b',
          'private_key': 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
          'peers': [
            {
              'address': 'other.example.com',
              'port': 51820,
              'public_key': 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=',
            },
          ],
        },
      ],
      'route': {
        'rules': <Map<String, dynamic>>[],
        'final': 'wg-a',
      },
    };
    final out = normalizeProfileConfigForCurrentPlatform(
      jsonEncode(config),
      targetPlatform: TargetPlatform.fuchsia,
    );
    final cfg = jsonDecode(out) as Map<String, dynamic>;
    final eps = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
    expect(
        eps.map((e) => e['tag']), containsAll(<dynamic>['wg-a', 'other-wg']));
    expect(eps.map((e) => e['tag']), isNot(contains('wg-b')));
    final other = eps.firstWhere((e) => e['tag'] == 'other-wg');
    expect(other['detour'], 'wg-a');
  });
}
