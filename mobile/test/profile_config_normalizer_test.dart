import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_models.dart';
import 'package:privatedeploy_mobile/features/cloud/cloud_node_config_builder.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_config_normalizer.dart';

void main() {
  group('managed DNS detours', () {
    test('preserves the complete cloud resolver detour on Android', () {
      final builtConfig = _buildCloudConfig(includeCdn: true);
      final built = jsonDecode(builtConfig) as Map<String, dynamic>;

      expect(_outboundTags(built), contains('dns-resolver'));
      expect(_dnsServer(built, 'dns-remote')['detour'], 'dns-resolver');
      expect(
        _dnsServer(built, 'dns-remote-google')['detour'],
        'dns-resolver',
      );

      final normalizedContent = normalizeProfileConfigForCurrentPlatform(
        builtConfig,
        targetPlatform: TargetPlatform.android,
      );
      final normalized = jsonDecode(normalizedContent) as Map<String, dynamic>;

      expect(_dnsServer(normalized, 'dns-remote')['detour'], 'dns-resolver');
      expect(
        _dnsServer(normalized, 'dns-remote-google')['detour'],
        'dns-resolver',
      );

      final dnsResolver = _outbound(normalized, 'dns-resolver');
      final directTier = _outbound(normalized, 'direct-auto');
      final cdnTier = _outbound(normalized, 'cdn-auto');
      final resolverMembers = List<String>.from(
        dnsResolver['outbounds'] as List<dynamic>,
      );
      final directMembers =
          List<String>.from(directTier['outbounds'] as List<dynamic>);
      final cdnMembers =
          List<String>.from(cdnTier['outbounds'] as List<dynamic>);
      expect(dnsResolver['interrupt_exist_connections'], isFalse);
      expect(resolverMembers, [...cdnMembers, ...directMembers]);
      expect(resolverMembers.toSet(), hasLength(resolverMembers.length));
      expect(resolverMembers.any((tag) => tag.contains('-CDN')), isTrue);
      expect(
        resolverMembers.every(_outboundTags(normalized).contains),
        isTrue,
      );

      final normalizedAgain = normalizeProfileConfigForCurrentPlatform(
        normalizedContent,
        targetPlatform: TargetPlatform.android,
      );
      expect(jsonDecode(normalizedAgain), normalized);
    });

    test('migrates a legacy direct-only cloud resolver to include CDN', () {
      final config = jsonDecode(
        _buildCloudConfig(includeCdn: true),
      ) as Map<String, dynamic>;
      final directMembers = List<String>.from(
        _outbound(config, 'direct-auto')['outbounds'] as List<dynamic>,
      );
      final cdnMembers = List<String>.from(
        _outbound(config, 'cdn-auto')['outbounds'] as List<dynamic>,
      );
      _outbound(config, 'dns-resolver')['outbounds'] = directMembers;

      final normalized = jsonDecode(
        normalizeProfileConfigForCurrentPlatform(
          jsonEncode(config),
          targetPlatform: TargetPlatform.android,
        ),
      ) as Map<String, dynamic>;

      final resolver = _outbound(normalized, 'dns-resolver');
      expect(resolver['interrupt_exist_connections'], isFalse);
      expect(resolver['outbounds'], [...cdnMembers, ...directMembers]);
      expect(_dnsServer(normalized, 'dns-remote')['detour'], 'dns-resolver');
      expect(
        _dnsServer(normalized, 'dns-remote-google')['detour'],
        'dns-resolver',
      );
    });

    test('flattens legacy nested cloud auto groups on Android', () {
      final config = jsonDecode(
        _buildCloudConfig(includeCdn: true),
      ) as Map<String, dynamic>;
      final directMembers = List<String>.from(
        _outbound(config, 'direct-auto')['outbounds'] as List<dynamic>,
      );
      final cdnMembers = List<String>.from(
        _outbound(config, 'cdn-auto')['outbounds'] as List<dynamic>,
      );
      _outbound(config, 'auto')['outbounds'] = <String>[
        'direct-auto',
        'cdn-auto',
      ];

      final normalizedContent = normalizeProfileConfigForCurrentPlatform(
        jsonEncode(config),
        targetPlatform: TargetPlatform.android,
      );
      final normalized = jsonDecode(normalizedContent) as Map<String, dynamic>;

      expect(
        _outbound(normalized, 'auto')['outbounds'],
        [...cdnMembers, ...directMembers],
      );
      // Keep the tier groups available as explicit manual choices.
      expect(
          _outboundTags(normalized), containsAll(['direct-auto', 'cdn-auto']));
      expect(
        jsonDecode(normalizeProfileConfigForCurrentPlatform(
          normalizedContent,
          targetPlatform: TargetPlatform.android,
        )),
        normalized,
      );
    });

    test('falls back to the selected proxy for non-managed detours', () {
      final config = jsonDecode(_buildCloudConfig()) as Map<String, dynamic>;
      _dnsServer(config, 'dns-remote')['detour'] = 'direct';
      _dnsServer(config, 'dns-remote-google')['detour'] = 'missing-resolver';

      final normalized = jsonDecode(
        normalizeProfileConfigForCurrentPlatform(
          jsonEncode(config),
          targetPlatform: TargetPlatform.android,
        ),
      ) as Map<String, dynamic>;

      expect(_dnsServer(normalized, 'dns-remote')['detour'], 'select');
      expect(
        _dnsServer(normalized, 'dns-remote-google')['detour'],
        'select',
      );
    });

    for (final invalidMembers in <List<String>>[
      const <String>[],
      const <String>['missing-proxy'],
    ]) {
      final label = invalidMembers.isEmpty ? 'empty' : 'dangling';
      final article = invalidMembers.isEmpty ? 'an' : 'a';
      test('drops $article $label managed resolver and falls back to select',
          () {
        final config = jsonDecode(
          _buildCloudConfig(includeCdn: true),
        ) as Map<String, dynamic>;
        final directLeaf = List<String>.from(
          _outbound(config, 'direct-auto')['outbounds'] as List<dynamic>,
        ).first;
        final selector = _outbound(config, 'select');
        selector['outbounds'] = List<String>.from(
          selector['outbounds'] as List<dynamic>,
        )
            .where((tag) => tag != 'direct-auto' && tag != 'cdn-auto')
            .toList(growable: false);
        _outbound(config, 'auto')['outbounds'] = <String>[directLeaf];
        final outbounds = config['outbounds'] as List<dynamic>;
        outbounds.removeWhere(
          (outbound) =>
              outbound is Map<String, dynamic> &&
              (outbound['tag'] == 'direct-auto' ||
                  outbound['tag'] == 'cdn-auto'),
        );
        _outbound(config, 'dns-resolver')['outbounds'] = invalidMembers;

        final normalized = jsonDecode(
          normalizeProfileConfigForCurrentPlatform(
            jsonEncode(config),
            targetPlatform: TargetPlatform.android,
          ),
        ) as Map<String, dynamic>;

        expect(_outboundTags(normalized), isNot(contains('dns-resolver')));
        expect(_dnsServer(normalized, 'dns-remote')['detour'], 'select');
        expect(
          _dnsServer(normalized, 'dns-remote-google')['detour'],
          'select',
        );
      });
    }
  });
}

String _buildCloudConfig({bool includeCdn = false}) {
  final instance = CloudInstance(
    id: 'node-1',
    provider: 'vultr',
    label: 'tokyo-1',
    status: 'active',
    region: 'nrt',
    plan: 'vc2-1c-1gb',
    ipv4: '192.0.2.1',
    nodeInfo: const NodeInfo(
      ssPort: 443,
      ssPassword: 'ss-password',
      hyPort: 0,
      hyPassword: '',
      hyServerName: '',
      hyInsecure: false,
      vlessPort: 9443,
      vlessUuid: 'uuid-123',
      vlessPublicKey: 'public-key',
      vlessShortId: 'short-id',
      vlessServerName: 'node.example.com',
      trojanPort: 0,
      trojanPassword: '',
      trojanServerName: '',
      trojanInsecure: false,
      vlessRelayPort: 47100,
    ),
  );

  return buildCloudNodeConfig(
    instance,
    targetPlatform: TargetPlatform.android,
    cdnEndpoint: includeCdn
        ? const CdnEndpoint(
            host: 'relay.example.com',
            pathSecret: '0123456789abcdef0123456789abcdef',
          )
        : null,
  )!;
}

Set<String> _outboundTags(Map<String, dynamic> config) =>
    (config['outbounds'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((outbound) => outbound['tag']?.toString())
        .whereType<String>()
        .toSet();

Map<String, dynamic> _dnsServer(Map<String, dynamic> config, String tag) {
  final dns = config['dns'] as Map<String, dynamic>;
  return (dns['servers'] as List<dynamic>)
      .whereType<Map<String, dynamic>>()
      .firstWhere((server) => server['tag'] == tag);
}

Map<String, dynamic> _outbound(Map<String, dynamic> config, String tag) =>
    (config['outbounds'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .firstWhere((outbound) => outbound['tag'] == tag);
