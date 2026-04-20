import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_config_builder.dart';

void main() {
  group('buildCloudNodeConfig', () {
    test('returns null when instance has no usable node info', () {
      final instance = CloudInstance(
        id: 'node-1',
        provider: 'vultr',
        label: 'tokyo-1',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
      );

      expect(buildCloudNodeConfig(instance), isNull);
    });

    test('builds sing-box config for available protocols', () {
      final instance = CloudInstance(
        id: 'node-1',
        provider: 'vultr',
        label: 'tokyo-1',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '1.2.3.4',
        nodeInfo: NodeInfo(
          ssPort: 443,
          ssPassword: 'ss-pass',
          hyPort: 8443,
          hyPassword: 'hy-pass',
          hyServerName: '',
          hyInsecure: false,
          vlessPort: 9443,
          vlessUuid: 'uuid-123',
          vlessPublicKey: 'abc+/==',
          vlessShortId: 'shortid',
          vlessServerName: 'example.com',
          trojanPort: 10443,
          trojanPassword: 'trojan-pass',
          trojanServerName: '',
          trojanInsecure: false,
        ),
      );

      final raw = buildCloudNodeConfig(instance);
      expect(raw, isNotNull);

      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;
      final selector = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'select',
      ) as Map<String, dynamic>;
      final tags = List<String>.from(selector['outbounds'] as List);

      expect(tags, containsAll(['auto', 'tokyo-1-SS', 'tokyo-1-Hy2']));
      expect(tags, containsAll(['tokyo-1-VLESS', 'tokyo-1-Trojan']));
      expect(selector['default'], 'tokyo-1-SS');

      final vless = outbounds.firstWhere(
        (item) =>
            item is Map<String, dynamic> && item['tag'] == 'tokyo-1-VLESS',
      ) as Map<String, dynamic>;
      final reality = (vless['tls'] as Map<String, dynamic>)['reality']
          as Map<String, dynamic>;

      expect(reality['public_key'], 'abc-_');
      expect(reality['short_id'], 'shortid');
    });

    test('prefers the measured fastest endpoint first in auto outbounds', () {
      final instance = CloudInstance(
        id: 'node-1',
        provider: 'vultr',
        label: 'tokyo-1',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '1.2.3.4',
        nodeInfo: const NodeInfo(
          ssPort: 443,
          ssPassword: 'ss-pass',
          hyPort: 0,
          hyPassword: '',
          hyServerName: '',
          hyInsecure: false,
          vlessPort: 0,
          vlessUuid: '',
          vlessPublicKey: '',
          vlessShortId: '',
          vlessServerName: '',
          trojanPort: 10443,
          trojanPassword: 'trojan-pass',
          trojanServerName: '',
          trojanInsecure: false,
        ),
      );

      final raw = buildCloudNodeConfig(
        instance,
        preferredEndpointLabel: 'Trojan',
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;
      final auto = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'auto',
      ) as Map<String, dynamic>;
      final selector = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'select',
      ) as Map<String, dynamic>;

      expect(
        List<String>.from(auto['outbounds'] as List).first,
        'tokyo-1-Trojan',
      );
      expect(selector['default'], 'tokyo-1-Trojan');
    });

    test('uses remote TLS DNS by default while keeping cloud APIs direct', () {
      final instance = CloudInstance(
        id: 'node-1',
        provider: 'vultr',
        label: 'tokyo-1',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '1.2.3.4',
        nodeInfo: const NodeInfo(
          ssPort: 443,
          ssPassword: 'ss-pass',
          hyPort: 0,
          hyPassword: '',
          hyServerName: '',
          hyInsecure: false,
          vlessPort: 0,
          vlessUuid: '',
          vlessPublicKey: '',
          vlessShortId: '',
          vlessServerName: '',
          trojanPort: 0,
          trojanPassword: '',
          trojanServerName: '',
          trojanInsecure: false,
        ),
      );

      final raw = buildCloudNodeConfig(instance);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final dns = decoded['dns'] as Map<String, dynamic>;
      final rules = List<Map<String, dynamic>>.from(
        (dns['rules'] as List<dynamic>).cast<Map<String, dynamic>>(),
      );

      final cloudApiRule = rules.firstWhere(
        (rule) => (rule['domain_suffix'] as List<dynamic>?)
            ?.contains('api.vultr.com') == true,
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
      final remoteServer = dnsServers.firstWhere(
        (server) => server['tag'] == 'dns-remote',
      );

      expect(cloudApiRule['server'], 'dns-direct');
      expect(defaultRule['server'], 'dns-remote');
      expect(localServer['detour'], 'direct');
      expect(remoteServer['address'], 'https://1.1.1.1/dns-query');
      expect(remoteServer.containsKey('address_resolver'), isFalse);
    });
  });
}
