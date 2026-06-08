import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/subscription/parser.dart';

Map<String, dynamic> _cfg(String raw) =>
    jsonDecode(SubscriptionParser.parseToSingboxConfig(raw)!)
        as Map<String, dynamic>;

List<Map<String, dynamic>> _proxyOutbounds(Map<String, dynamic> cfg) =>
    (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .where((o) => !['selector', 'urltest', 'direct', 'dns', 'block']
            .contains(o['type']))
        .toList();

void main() {
  test('vless ws node emits a ws transport block (was dropped before)', () {
    final cfg = _cfg('vless://uuid-1@h.example.com:443'
        '?type=ws&path=%2Fwspath&host=cdn.example.com&security=tls&sni=cdn.example.com#node');
    final o = _proxyOutbounds(cfg).single;
    expect(o['type'], 'vless');
    expect(o['transport'], isNotNull);
    expect(o['transport']['type'], 'ws');
    expect(o['transport']['path'], '/wspath');
    expect(o['transport']['headers']['Host'], 'cdn.example.com');
  });

  test('trojan password + fragment name are percent-decoded', () {
    final cfg = _cfg('trojan://p%40ss%23word@h.example.com:443#%E9%A6%99%E6%B8%AF');
    final o = _proxyOutbounds(cfg).single;
    expect(o['type'], 'trojan');
    expect(o['password'], 'p@ss#word');
    expect(o['tag'], '香港');
  });

  test('shadowsocks with ?plugin= keeps the real port (was 0)', () {
    final cfg = _cfg(
        'ss://YWVzLTI1Ni1nY206cGFzcw==@h.example.com:8388?plugin=obfs-local;obfs=http#ss');
    final o = _proxyOutbounds(cfg).single;
    expect(o['type'], 'shadowsocks');
    expect(o['server_port'], 8388);
    expect(o['method'], 'aes-256-gcm');
    expect(o['password'], 'pass');
  });

  test('duplicate node names get unique tags (whole config no longer rejected)',
      () {
    final cfg = _cfg('trojan://a@h1.example.com:443#dup\n'
        'trojan://b@h2.example.com:443#dup');
    final tags =
        _proxyOutbounds(cfg).map((o) => o['tag'] as String).toList();
    expect(tags.length, 2);
    expect(tags.toSet().length, 2, reason: 'tags must be unique: $tags');
  });

  test('vmess ws node emits transport', () {
    final vmess = base64.encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': 'vm',
      'add': 'h.example.com',
      'port': '443',
      'id': 'uuid-2',
      'net': 'ws',
      'path': '/vm',
      'host': 'cdn.example.com',
      'tls': 'tls',
    })));
    final cfg = _cfg('vmess://$vmess');
    final o = _proxyOutbounds(cfg).single;
    expect(o['type'], 'vmess');
    expect(o['transport']['type'], 'ws');
    expect(o['transport']['path'], '/vm');
  });
}
