import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/core/subscription/parser.dart';

void main() {
  group('SubscriptionParser URI Parsing', () {
    test('parse Shadowsocks URI', () {
      final raw = 'ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@1.2.3.4:8388#MyServer';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      // selector + urltest + node + direct = 4. The legacy dns/block special
      // outbounds were removed (deprecated in sing-box 1.11, removed in 1.13);
      // DNS hijack is now a route-rule action.
      expect(outbounds.length, 4);

      final ssOutbound =
          outbounds.firstWhere((o) => o['type'] == 'shadowsocks');
      expect(ssOutbound['server'], '1.2.3.4');
      expect(ssOutbound['server_port'], 8388);
      expect(ssOutbound['method'], 'aes-256-gcm');
      expect(ssOutbound['password'], 'testpass');
    });

    test('parse VLESS Reality URI', () {
      final raw =
          'vless://uuid-1234@5.6.7.8:443?security=reality&sni=www.microsoft.com&pbk=pubkey123&sid=abcd&flow=xtls-rprx-vision&type=tcp&fp=chrome#VLESS-Node';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      final vlessOutbound = outbounds.firstWhere((o) => o['type'] == 'vless');
      expect(vlessOutbound['server'], '5.6.7.8');
      expect(vlessOutbound['uuid'], 'uuid-1234');
      expect(vlessOutbound['flow'], 'xtls-rprx-vision');
      expect(vlessOutbound['tls']['reality']['enabled'], true);
      expect(vlessOutbound['tls']['reality']['public_key'], 'pubkey123');
    });

    test('parse Trojan URI', () {
      final raw = 'trojan://mypassword@9.8.7.6:443?sni=example.com#Trojan-Node';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      final trojanOutbound = outbounds.firstWhere((o) => o['type'] == 'trojan');
      expect(trojanOutbound['server'], '9.8.7.6');
      expect(trojanOutbound['password'], 'mypassword');
      expect(trojanOutbound['tls']['server_name'], 'example.com');
    });

    test('parse Hysteria2 URI', () {
      final raw =
          'hysteria2://hypass@10.0.0.1:8443?insecure=1&sni=test.com#Hy2-Node';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      final hy2Outbound = outbounds.firstWhere((o) => o['type'] == 'hysteria2');
      expect(hy2Outbound['server'], '10.0.0.1');
      expect(hy2Outbound['password'], 'hypass');
      expect(hy2Outbound['tls']['insecure'], true);
    });

    test('parse hy2:// short URI', () {
      final raw = 'hy2://pass@1.1.1.1:443#Short';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);
    });

    test('parse base64 encoded URI list', () {
      final uriList =
          'ss://YWVzLTI1Ni1nY206dGVzdA==@1.1.1.1:1234#SS1\ntrojan://pass@2.2.2.2:443#TJ1';
      final encoded = base64Encode(utf8.encode(uriList));
      final config = SubscriptionParser.parseToSingboxConfig(encoded);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      // selector + urltest + 2 nodes + direct = 5 (legacy dns/block special
      // outbounds removed; DNS hijack is now a route-rule action).
      expect(outbounds.length, 5);
    });

    test('parse multi-line plain URI list', () {
      final raw = '''
ss://YWVzLTI1Ni1nY206cGFzcw==@1.1.1.1:8388#SS-1
trojan://pass@2.2.2.2:443?sni=example.com#Trojan-1
vless://uuid@3.3.3.3:443?security=tls&sni=test.com#VLESS-1
''';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      final nodeOutbounds = outbounds
          .where((o) => !['selector', 'urltest', 'direct', 'dns', 'block']
              .contains(o['type']))
          .toList();
      expect(nodeOutbounds.length, 3);
    });

    test('parse sing-box JSON directly', () {
      final singboxJson = '{"outbounds":[{"type":"direct","tag":"direct"}]}';
      final config = SubscriptionParser.parseToSingboxConfig(singboxJson);
      expect(config, singboxJson);
    });

    test('parse HTTP JSON response body directly', () {
      final responseBody = {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      };

      final config =
          SubscriptionParser.parseResponseDataToSingboxConfig(responseBody);

      expect(config, isNotNull);
      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List<dynamic>;
      expect(outbounds.single['type'], 'direct');
      expect(outbounds.single['tag'], 'direct');
    });

    test('parse HTTP plain-text response body directly', () {
      const responseBody =
          'ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@1.2.3.4:8388#MyServer';

      final config =
          SubscriptionParser.parseResponseDataToSingboxConfig(responseBody);

      expect(config, isNotNull);
      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List<dynamic>;
      final ssOutbound =
          outbounds.firstWhere((o) => o['type'] == 'shadowsocks');
      expect(ssOutbound['server'], '1.2.3.4');
      expect(ssOutbound['server_port'], 8388);
    });

    test('returns null for garbage input', () {
      final config =
          SubscriptionParser.parseToSingboxConfig('this is not a valid input');
      expect(config, isNull);
    });

    test('generated config has required structure', () {
      final raw = 'ss://YWVzLTI1Ni1nY206cGFzcw==@1.1.1.1:8388#Test';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      expect(json.containsKey('log'), true);
      expect((json['log'] as Map<String, dynamic>)['level'], 'info');
      expect(json.containsKey('dns'), true);
      expect(json.containsKey('inbounds'), true);
      expect(json.containsKey('outbounds'), true);
      expect(json.containsKey('route'), true);

      // Has tun inbound
      final inbounds = json['inbounds'] as List;
      expect(inbounds.any((i) => i['type'] == 'tun'), true);
      final tunInbound = inbounds.firstWhere((i) => i['type'] == 'tun')
          as Map<String, dynamic>;
      expect(tunInbound['stack'], 'gvisor');

      // Has selector and urltest
      final outbounds = json['outbounds'] as List;
      expect(outbounds.any((o) => o['type'] == 'selector'), true);
      expect(outbounds.any((o) => o['type'] == 'urltest'), true);
      final selector = outbounds.firstWhere((o) => o['type'] == 'selector');
      final urltest = outbounds.firstWhere((o) => o['type'] == 'urltest');
      expect(selector['default'], 'auto');
      expect(selector['interrupt_exist_connections'], isTrue);
      expect(urltest['interrupt_exist_connections'], isTrue);
      expect(urltest.containsKey('idle_timeout'), isFalse);

      final dns = json['dns'] as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules = List<Map<String, dynamic>>.from(
        (dns['rules'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );
      final cloudApiRule = rules.firstWhere(
        (rule) =>
            (rule['domain_suffix'] as List<dynamic>?)
                ?.contains('api.vultr.com') ==
            true,
      );
      final defaultRule = rules.firstWhere(
        (rule) => (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
      );

      final dnsServers = List<Map<String, dynamic>>.from(
        (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );
      final localServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-local',
      );
      final bootstrapServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-direct',
      );
      final cnServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-cn',
      );
      final remoteServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-remote',
      );
      final remoteFallbackServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-remote-google',
      );

      expect(cloudApiRule['server'], 'dns-direct');
      expect(defaultRule['server'], 'dns-remote');
      expect(bootstrapServer['address'], 'https://1.12.12.12/dns-query');
      expect(cnServer['address'], 'https://223.5.5.5/dns-query');
      expect(localServer['detour'], 'direct');
      expect(remoteServer['address'], 'https://1.1.1.1/dns-query');
      expect(remoteFallbackServer['address'], 'https://8.8.8.8/dns-query');
      expect(remoteServer.containsKey('address_resolver'), isFalse);
      expect((dns['cache_capacity'] as int?) ?? 0, 4096);
      expect(dns['reverse_mapping'], isTrue);
      expect(route['auto_detect_interface'], isTrue);
      expect(
        rules.any(
          (rule) =>
              rule['server'] == 'dns-remote-google' &&
              (rule['domain_suffix'] as List<dynamic>?)
                      ?.contains('youtube.com') ==
                  true,
        ),
        isTrue,
      );
    });
  });

  group('SubscriptionParser VMess', () {
    test('parse VMess base64 JSON URI', () {
      final vmessJson = {
        'v': '2',
        'ps': 'VMess-Test',
        'add': '4.5.6.7',
        'port': '443',
        'id': 'uuid-vmess',
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'tls': 'tls',
        'sni': 'vmess.example.com',
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(vmessJson)));
      final raw = 'vmess://$encoded';
      final config = SubscriptionParser.parseToSingboxConfig(raw);
      expect(config, isNotNull);

      final json = jsonDecode(config!) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      final vmessOutbound = outbounds.firstWhere((o) => o['type'] == 'vmess');
      expect(vmessOutbound['server'], '4.5.6.7');
      expect(vmessOutbound['uuid'], 'uuid-vmess');
    });
  });
}
