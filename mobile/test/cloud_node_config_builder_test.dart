import 'dart:convert';

import 'package:flutter/foundation.dart';
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

    test(
        'appends CDN-fronted vless+ws outbound when worker host and relay '
        'port are present', () {
      final instance = CloudInstance(
        id: 'node-cdn',
        provider: 'vultr',
        label: 'lax-1',
        status: 'active',
        region: 'lax',
        plan: 'vc2-1c-1gb',
        ipv4: '5.6.7.8',
        nodeInfo: NodeInfo(
          ssPort: 0,
          ssPassword: '',
          hyPort: 0,
          hyPassword: '',
          hyServerName: '',
          hyInsecure: null,
          vlessPort: 9443,
          vlessUuid: 'uuid-cdn',
          vlessPublicKey: 'pub',
          vlessShortId: 'sid',
          vlessServerName: 'example.com',
          trojanPort: 0,
          trojanPassword: '',
          trojanServerName: '',
          trojanInsecure: null,
          vlessRelayPort: 47100,
        ),
      );

      final raw = buildCloudNodeConfig(
        instance,
        cdnEndpoint: const CdnEndpoint(
          host: 'pd-relay-lax.acme.workers.dev',
        ),
      );
      expect(raw, isNotNull);

      final outbounds = (jsonDecode(raw!) as Map)['outbounds'] as List;
      final cdn = outbounds.firstWhere(
        (o) => o is Map && o['tag'] == 'lax-1-CDN',
        orElse: () => null,
      );
      expect(cdn, isNotNull,
          reason: 'CDN variant should be appended when worker host present');

      final cdnMap = cdn as Map<String, dynamic>;
      expect(cdnMap['type'], 'vless');
      expect(cdnMap['server'], 'pd-relay-lax.acme.workers.dev');
      expect(cdnMap['server_port'], 443);
      expect(cdnMap['uuid'], 'uuid-cdn');

      final transport = cdnMap['transport'] as Map<String, dynamic>;
      expect(transport['type'], 'ws');
      expect(transport['path'], '/?ed=2560');
      expect((transport['headers'] as Map)['Host'],
          'pd-relay-lax.acme.workers.dev');

      final tls = cdnMap['tls'] as Map<String, dynamic>;
      expect(tls['enabled'], true);
      expect(tls['server_name'], 'pd-relay-lax.acme.workers.dev');
      // CDN variant must NOT carry the Reality block — that fields-based
      // protocol is what the dumb WS↔TCP relay can't handle.
      expect(tls.containsKey('reality'), isFalse);
    });

    test('omits CDN variant when relay port is zero (older deploys)', () {
      final instance = CloudInstance(
        id: 'old-node',
        provider: 'vultr',
        label: 'old-1',
        status: 'active',
        region: 'lax',
        plan: 'vc2-1c-1gb',
        ipv4: '9.9.9.9',
        nodeInfo: NodeInfo(
          ssPort: 0,
          ssPassword: '',
          hyPort: 0,
          hyPassword: '',
          hyServerName: '',
          hyInsecure: null,
          vlessPort: 9443,
          vlessUuid: 'uuid-old',
          vlessPublicKey: 'pub',
          vlessShortId: 'sid',
          vlessServerName: 'example.com',
          trojanPort: 0,
          trojanPassword: '',
          trojanServerName: '',
          trojanInsecure: null,
          // vlessRelayPort defaults to 0 — pre-Phase-5 deploys.
        ),
      );

      final raw = buildCloudNodeConfig(
        instance,
        cdnEndpoint: const CdnEndpoint(
          host: 'pd-relay-old.acme.workers.dev',
        ),
      );
      expect(raw, isNotNull);

      final outbounds = (jsonDecode(raw!) as Map)['outbounds'] as List;
      final tags = outbounds
          .whereType<Map>()
          .map((o) => o['tag'])
          .where((t) => t != null)
          .toList();
      expect(tags, isNot(contains('old-1-CDN')),
          reason:
              'CDN variant must NOT be added when node lacks vlessRelayPort');
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
      final log = decoded['log'] as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;
      final selector = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'select',
      ) as Map<String, dynamic>;
      final urltest = outbounds.firstWhere(
        (item) => item is Map<String, dynamic> && item['tag'] == 'auto',
      ) as Map<String, dynamic>;
      final tags = List<String>.from(selector['outbounds'] as List);

      expect(log['level'], 'info');
      expect(tags, containsAll(['auto', 'tokyo-1-SS', 'tokyo-1-Hy2']));
      expect(tags, containsAll(['tokyo-1-VLESS', 'tokyo-1-Trojan']));
      expect(selector['default'], 'auto');
      expect(selector['interrupt_exist_connections'], isTrue);
      expect(urltest['interrupt_exist_connections'], isTrue);
      expect(urltest.containsKey('idle_timeout'), isFalse);

      final vless = outbounds.firstWhere(
        (item) =>
            item is Map<String, dynamic> && item['tag'] == 'tokyo-1-VLESS',
      ) as Map<String, dynamic>;
      final reality = (vless['tls'] as Map<String, dynamic>)['reality']
          as Map<String, dynamic>;

      expect(reality['public_key'], 'abc-_');
      expect(reality['short_id'], 'shortid');
    });

    test('manual fastest endpoint preference becomes the active selector', () {
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
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((item) => item['tag'] == 'select');

      expect(selector['outbounds'], ['tokyo-1-Trojan']);
      expect(selector['default'], 'tokyo-1-Trojan');
      expect(outbounds.where((item) => item['tag'] == 'auto'), isEmpty);
    });

    test('defaults to auto selector when no manual endpoint is chosen', () {
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
          hyPort: 8443,
          hyPassword: 'hy-pass',
          hyServerName: 'example.com',
          hyInsecure: false,
          vlessPort: 9443,
          vlessUuid: 'uuid-123',
          vlessPublicKey: 'abc+/==',
          vlessShortId: 'shortid',
          vlessServerName: 'example.com',
          trojanPort: 10443,
          trojanPassword: 'trojan-pass',
          trojanServerName: 'example.com',
          trojanInsecure: false,
        ),
      );

      final raw = buildCloudNodeConfig(instance);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((item) => item['tag'] == 'select');

      expect(selector['outbounds'], [
        'auto',
        'tokyo-1-SS',
        'tokyo-1-Hy2',
        'tokyo-1-VLESS',
        'tokyo-1-Trojan',
      ]);
      expect(selector['default'], 'auto');
    });

    test('manual endpoint selection omits auto urltest and unused protocols',
        () {
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

      final raw = buildCloudNodeConfig(
        instance,
        preferredEndpointLabel: 'VLESS',
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere(
        (item) => item['tag'] == 'select',
      );

      expect(selector['outbounds'], ['tokyo-1-VLESS']);
      expect(selector['default'], 'tokyo-1-VLESS');
      expect(
        outbounds.where((item) => item['tag'] == 'auto'),
        isEmpty,
      );
      expect(
        outbounds.where((item) => item['tag'] == 'tokyo-1-VLESS'),
        hasLength(1),
      );
      expect(
        outbounds.where((item) => item['tag'] == 'tokyo-1-SS'),
        isEmpty,
      );
      expect(
        outbounds.where((item) => item['tag'] == 'tokyo-1-Hy2'),
        isEmpty,
      );
      expect(
        outbounds.where((item) => item['tag'] == 'tokyo-1-Trojan'),
        isEmpty,
      );
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

    test('uses system stack and preserves all cloud outbounds on Android', () {
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

      final raw = buildCloudNodeConfig(
        instance,
        targetPlatform: TargetPlatform.android,
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final inbounds =
          (decoded['inbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final route = decoded['route'] as Map<String, dynamic>;

      expect(inbounds.single['stack'], 'system');
      expect(route['auto_detect_interface'], isTrue);
      expect(route['default_network_strategy'], 'default');
      expect(
        outbounds.where((outbound) => outbound['type'] == 'hysteria2'),
        isNotEmpty,
      );
      expect(
        outbounds.where((outbound) => outbound['type'] == 'vless'),
        isNotEmpty,
      );
      expect(
        outbounds.where((outbound) => outbound['type'] == 'shadowsocks'),
        isNotEmpty,
      );
      expect(
        outbounds.where((outbound) => outbound['type'] == 'trojan'),
        isNotEmpty,
      );
    });

    test('honors preferred endpoint on Android when it is supported', () {
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
        targetPlatform: TargetPlatform.android,
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((item) => item['tag'] == 'select');

      expect(selector['outbounds'], ['tokyo-1-Trojan']);
      expect(selector['default'], 'tokyo-1-Trojan');
      expect(outbounds.where((item) => item['tag'] == 'auto'), isEmpty);
    });

    test('failover instances enroll into urltest pool in auto mode', () {
      NodeInfo info(String suffix) => NodeInfo(
            ssPort: 443,
            ssPassword: 'ss-$suffix',
            hyPort: 8443,
            hyPassword: 'hy-$suffix',
            hyServerName: '',
            hyInsecure: false,
            vlessPort: 9443,
            vlessUuid: 'uuid-$suffix',
            vlessPublicKey: 'abc+/==',
            vlessShortId: 'sid-$suffix',
            vlessServerName: 'example.com',
            trojanPort: 10443,
            trojanPassword: 'trojan-$suffix',
            trojanServerName: '',
            trojanInsecure: false,
          );

      final active = CloudInstance(
        id: 'node-active',
        provider: 'vultr',
        label: 'lax-1',
        status: 'active',
        region: 'lax',
        plan: 'vc2-1c-1gb',
        ipv4: '1.1.1.1',
        nodeInfo: info('a'),
      );
      final failoverA = CloudInstance(
        id: 'node-fail-a',
        provider: 'vultr',
        label: 'tyo-2',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '2.2.2.2',
        nodeInfo: info('b'),
      );
      final failoverB = CloudInstance(
        id: 'node-fail-b',
        provider: 'vultr',
        label: 'sgp-3',
        status: 'active',
        region: 'sgp',
        plan: 'vc2-1c-1gb',
        ipv4: '3.3.3.3',
        nodeInfo: info('c'),
      );

      final raw = buildCloudNodeConfig(
        active,
        failoverInstances: [failoverA, failoverB],
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final urltest = outbounds.firstWhere((o) => o['tag'] == 'auto');
      final pool = List<String>.from(urltest['outbounds'] as List);

      // Active node's protocols come first, then each failover's protocols.
      expect(pool, contains('lax-1-VLESS'));
      expect(pool, contains('lax-1-SS'));
      expect(pool, contains('tyo-2-VLESS'));
      expect(pool, contains('tyo-2-SS'));
      expect(pool, contains('sgp-3-VLESS'));
      expect(pool, contains('sgp-3-Trojan'));

      // Each failover endpoint must have a real outbound entry, not just a
      // tag in the urltest pool.
      final failoverVless = outbounds.firstWhere(
        (o) => o['tag'] == 'tyo-2-VLESS',
        orElse: () => const {},
      );
      expect(failoverVless['server'], '2.2.2.2',
          reason: 'failover instance outbound must point to its own IP');

      // Selector exposes everything so manual override still works.
      final selector = outbounds.firstWhere((o) => o['tag'] == 'select');
      expect(selector['outbounds'], contains('tyo-2-VLESS'));
      expect(selector['default'], 'auto');
    });

    test('failover ignored when manual protocol selection is active', () {
      NodeInfo info(String suffix) => NodeInfo(
            ssPort: 443,
            ssPassword: 'ss-$suffix',
            hyPort: 0,
            hyPassword: '',
            hyServerName: '',
            hyInsecure: false,
            vlessPort: 9443,
            vlessUuid: 'uuid-$suffix',
            vlessPublicKey: 'abc+/==',
            vlessShortId: 'sid-$suffix',
            vlessServerName: 'example.com',
            trojanPort: 10443,
            trojanPassword: 'trojan-$suffix',
            trojanServerName: '',
            trojanInsecure: false,
          );

      final active = CloudInstance(
        id: 'node-active',
        provider: 'vultr',
        label: 'lax-1',
        status: 'active',
        region: 'lax',
        plan: 'vc2-1c-1gb',
        ipv4: '1.1.1.1',
        nodeInfo: info('a'),
      );
      final failover = CloudInstance(
        id: 'node-fail',
        provider: 'vultr',
        label: 'tyo-2',
        status: 'active',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ipv4: '2.2.2.2',
        nodeInfo: info('b'),
      );

      final raw = buildCloudNodeConfig(
        active,
        preferredEndpointLabel: 'VLESS',
        failoverInstances: [failover],
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((o) => o['tag'] == 'select');

      expect(selector['outbounds'], ['lax-1-VLESS']);
      expect(outbounds.where((o) => o['tag'] == 'auto'), isEmpty);
      expect(outbounds.where((o) => o['tag'] == 'tyo-2-VLESS'), isEmpty,
          reason: 'manual protocol pin must keep config narrow; failover only '
              'applies in auto mode');
    });

    test('failover skips instances with no usable node info or IP', () {
      final active = CloudInstance(
        id: 'node-active',
        provider: 'vultr',
        label: 'lax-1',
        status: 'active',
        region: 'lax',
        plan: 'vc2-1c-1gb',
        ipv4: '1.1.1.1',
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
      final noIp = CloudInstance(
        id: 'no-ip',
        provider: 'vultr',
        label: 'pending-1',
        status: 'pending',
        region: 'sgp',
        plan: 'vc2-1c-1gb',
      );
      final noInfo = CloudInstance(
        id: 'no-info',
        provider: 'vultr',
        label: 'starting-1',
        status: 'active',
        region: 'sgp',
        plan: 'vc2-1c-1gb',
        ipv4: '2.2.2.2',
      );

      final raw = buildCloudNodeConfig(
        active,
        failoverInstances: [noIp, noInfo],
      );
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final urltest = outbounds.firstWhere((o) => o['tag'] == 'auto');
      final pool = List<String>.from(urltest['outbounds'] as List);

      // No failover tags should leak in.
      expect(pool, ['lax-1-SS']);
    });

    test('urltest probes via IP-literal so DNS deadlock cannot stall it', () {
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
      final outbounds =
          (decoded['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final urltest = outbounds.firstWhere((o) => o['tag'] == 'auto');
      final url = urltest['url']?.toString() ?? '';

      // Must be IP-literal: hostname-based probes deadlock when DNS itself
      // routes through the urltest pool and every initial member is down.
      final hostMatch = RegExp(r'^https?://([^/:]+)').firstMatch(url);
      expect(hostMatch, isNotNull,
          reason: 'urltest url must include host: $url');
      final host = hostMatch!.group(1)!;
      final isIpLiteral =
          RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(host);
      expect(isIpLiteral, isTrue,
          reason: 'urltest probe must be an IP-literal so it never depends '
              'on DNS resolution: got $host');
    });

    test('extracts the active cloud endpoint label from selector default', () {
      const raw = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "fra-node-SS", "fra-node-Trojan"],
      "default": "fra-node-SS"
    }
  ]
}
''';

      expect(activeCloudNodeEndpointLabel(raw), 'Shadowsocks');
      expect(activeCloudNodeEndpointLabel('{"outbounds": []}'), isNull);
      expect(
        activeCloudNodeEndpointLabel(
          '{"outbounds":[{"type":"selector","tag":"select","default":"auto"}]}',
        ),
        isNull,
      );
    });
  });
}
