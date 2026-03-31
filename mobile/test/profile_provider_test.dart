import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:privatedeploy_mobile/features/profiles/bundled_rule_set_registry.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/features/settings/app_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Profile Model Tests', () {
    test('Profile.fromJson parses correctly', () {
      final json = {
        'id': '123',
        'name': 'Test Profile',
        'subscription_url': 'https://example.com/sub',
        'content': '{"outbounds":[]}',
        'is_active': true,
        'created_at': '2024-01-01T00:00:00.000Z',
        'updated_at': '2024-01-02T00:00:00.000Z',
      };

      final profile = Profile.fromJson(json);
      expect(profile.id, '123');
      expect(profile.name, 'Test Profile');
      expect(profile.subscriptionUrl, 'https://example.com/sub');
      expect(profile.content, '{"outbounds":[]}');
      expect(profile.isActive, true);
    });

    test('Profile.copyWith works', () {
      final profile = Profile(
        id: '1',
        name: 'Original',
        isActive: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final updated = profile.copyWith(name: 'Updated', isActive: true);
      expect(updated.name, 'Updated');
      expect(updated.isActive, true);
      expect(updated.id, '1');
    });

    test('Profile.toJson roundtrip', () {
      final profile = Profile(
        id: '1',
        name: 'Test',
        subscriptionUrl: 'https://test.com',
        content: '{}',
        isActive: false,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 2),
      );

      final json = profile.toJson();
      final restored = Profile.fromJson(json);
      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.subscriptionUrl, profile.subscriptionUrl);
      expect(restored.content, profile.content);
    });

    test('normalizeConfigForCurrentPlatform rewrites Android tun stack', () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun",
      "stack": "system"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final inbounds = json['inbounds'] as List<dynamic>;
      expect((inbounds.first as Map<String, dynamic>)['stack'], 'gvisor');
    });

    test(
        'normalizeConfigForCurrentPlatform blocks Android Private DNS probes to tun subnet',
        () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun",
      "inet4_address": "172.19.0.1/30"
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-ss"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "geoip": ["private"],
        "outbound": "direct"
      }
    ]
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final outbounds =
          (json['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final route = json['route'] as Map<String, dynamic>;
      final rules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();

      expect(
        outbounds.any((outbound) => outbound['tag'] == 'block'),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              rule['outbound'] == 'block' &&
              rule['network'] == 'tcp' &&
              rule['port'] == 853 &&
              listEquals(
                (rule['ip_cidr'] as List<dynamic>?)?.cast<String>(),
                ['172.19.0.0/30'],
              ),
        ),
        isTrue,
      );
    });

    test(
        'normalizeConfigForCurrentPlatform removes Android hysteria2 outbounds',
        () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun",
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-ss", "node-hy2"]
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss", "node-hy2"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "hysteria2",
      "tag": "node-hy2"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List<dynamic>;

      expect(
        outbounds.where(
            (item) => (item as Map<String, dynamic>)['type'] == 'hysteria2'),
        isEmpty,
      );

      final selector = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'select');
      expect(selector['outbounds'], ['auto', 'node-ss']);

      final auto = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'auto');
      expect(auto['outbounds'], ['node-ss']);
    });

    test(
        'normalizeConfigForCurrentPlatform removes Android vless reality outbounds',
        () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun",
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "auto",
      "outbounds": ["auto", "node-ss", "node-vless", "node-trojan"]
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss", "node-vless", "node-trojan"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "vless",
      "tag": "node-vless",
      "tls": {
        "enabled": true,
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "abc",
          "short_id": "1234"
        }
      }
    },
    {
      "type": "trojan",
      "tag": "node-trojan"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List<dynamic>;

      expect(
        outbounds.where(
            (item) => (item as Map<String, dynamic>)['tag'] == 'node-vless'),
        isEmpty,
      );

      final selector = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'select');
      expect(selector['outbounds'], ['auto', 'node-ss', 'node-trojan']);
      expect(selector['default'], 'auto');

      final auto = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'auto');
      expect(auto['outbounds'], ['node-ss', 'node-trojan']);
    });

    test('normalizeConfigForCurrentPlatform applies split routing defaults',
        () {
      const config = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-ss"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "geoip": ["private"],
        "outbound": "direct"
      }
    ]
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        routingSettings: VpnRoutingSettings.defaults,
        bundledRuleSetPaths: const BundledRuleSetPaths(
          geositeCnPath: '/tmp/geosite-cn.srs',
          geoipCnPath: '/tmp/geoip-cn.srs',
        ),
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List<dynamic>).cast<Map>();
      final ruleSets = (route['rule_set'] as List<dynamic>).cast<Map>();
      final experimental = json['experimental'] as Map<String, dynamic>;

      expect(route['final'], 'select');
      expect(
        rules.any((rule) => rule['ip_is_private'] == true),
        isTrue,
      );
      expect(
        rules.any((rule) => rule['rule_set'] == 'pd-geosite-cn'),
        isTrue,
      );
      expect(
        rules.any((rule) => rule['rule_set'] == 'pd-geoip-cn'),
        isTrue,
      );
      expect(
        ruleSets.any((ruleSet) => ruleSet['tag'] == 'pd-geosite-cn'),
        isTrue,
      );
      expect(
        ruleSets.any(
          (ruleSet) =>
              ruleSet['tag'] == 'pd-geosite-cn' &&
              ruleSet['type'] == 'local' &&
              ruleSet['path'] == '/tmp/geosite-cn.srs',
        ),
        isTrue,
      );
      expect(
        ruleSets.any((ruleSet) => ruleSet['tag'] == 'pd-geoip-cn'),
        isTrue,
      );
      expect(
        ruleSets.any(
          (ruleSet) =>
              ruleSet['tag'] == 'pd-geoip-cn' &&
              ruleSet['type'] == 'local' &&
              ruleSet['path'] == '/tmp/geoip-cn.srs',
        ),
        isTrue,
      );
      expect(
        ((experimental['cache_file'] as Map<String, dynamic>)['enabled']),
        true,
      );
    });

    test('normalizeConfigForCurrentPlatform applies global routing mode', () {
      const config = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-ss"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        routingSettings: const VpnRoutingSettings(
          mode: VpnRoutingMode.global,
          directCnDomains: true,
          directCnIpRanges: true,
        ),
        bundledRuleSetPaths: const BundledRuleSetPaths(
          geositeCnPath: '/tmp/geosite-cn.srs',
          geoipCnPath: '/tmp/geoip-cn.srs',
        ),
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules = (route['rules'] as List<dynamic>).cast<Map>();

      expect(route['final'], 'select');
      expect(
        rules.any((rule) => rule['ip_is_private'] == true),
        isTrue,
      );
      expect(
        rules.any((rule) => rule['rule_set'] == 'pd-geosite-cn'),
        isFalse,
      );
      expect(
        rules.any((rule) => rule['rule_set'] == 'pd-geoip-cn'),
        isFalse,
      );
      expect(route.containsKey('rule_set'), isFalse);
    });

    test('normalizeConfigForCurrentPlatform adds custom proxy and direct rules',
        () {
      const config = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-ss"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-ss"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-ss"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ]
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        routingSettings: const VpnRoutingSettings(
          customDirectPackages: ['com.example.mail'],
          customProxyPackages: ['com.example.browser'],
          customDirectDomains: ['corp.local'],
          customProxyDomains: ['openai.com'],
          customDirectCidrs: ['10.10.0.0/16'],
          customProxyCidrs: ['203.0.113.0/24'],
        ),
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();

      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['package_name'] as List<dynamic>?)?.cast<String>(),
                ['com.example.browser'],
              ) &&
              rule['outbound'] == 'select',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['package_name'] as List<dynamic>?)?.cast<String>(),
                ['com.example.mail'],
              ) &&
              rule['outbound'] == 'direct',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['domain_suffix'] as List<dynamic>?)?.cast<String>(),
                ['openai.com'],
              ) &&
              rule['outbound'] == 'select',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['domain_suffix'] as List<dynamic>?)?.cast<String>(),
                ['corp.local'],
              ) &&
              rule['outbound'] == 'direct',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['ip_cidr'] as List<dynamic>?)?.cast<String>(),
                ['203.0.113.0/24'],
              ) &&
              rule['outbound'] == 'select',
        ),
        isTrue,
      );
      expect(
        rules.any(
          (rule) =>
              listEquals(
                (rule['ip_cidr'] as List<dynamic>?)?.cast<String>(),
                ['10.10.0.0/16'],
              ) &&
              rule['outbound'] == 'direct',
        ),
        isTrue,
      );
    });
  });

  group('Profile Provider Storage Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('privatedeploy_profiles_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('createProfile persists and activates the first profile', () async {
      final provider = ProfileProvider();

      final success = await provider.createProfile(
        name: 'Cloud: sgp-smoke',
        content: '{"outbounds":[]}',
        allowReservedPrefix: true,
      );

      expect(success, isTrue);
      expect(provider.profiles, hasLength(1));
      expect(provider.activeProfile?.name, 'Cloud: sgp-smoke');

      final boxFile = File('${tempDir.path}/profiles.hive');
      expect(boxFile.existsSync(), isTrue);
      expect(boxFile.lengthSync(), greaterThan(0));
    });

    test('deleteProfileByName clears the active cloud profile', () async {
      final provider = ProfileProvider();

      await provider.createProfile(
        name: 'Cloud: fra-smoke',
        content: '{"outbounds":[]}',
        allowReservedPrefix: true,
      );

      final deleted = await provider.deleteProfileByName('Cloud: fra-smoke');

      expect(deleted, isTrue);
      expect(provider.profiles, isEmpty);
      expect(provider.activeProfile, isNull);
    });

    test(
        'pruneMissingCloudProfiles removes stale cloud profiles and clears active',
        () async {
      final provider = ProfileProvider();

      await provider.createProfile(
        name: 'Cloud: missing-node',
        content: '{"outbounds":[]}',
        allowReservedPrefix: true,
      );
      await provider.createProfile(
        name: 'Cloud: keep-node',
        content: '{"outbounds":[]}',
        allowReservedPrefix: true,
      );
      final keepProfile = provider.getProfileByName('Cloud: keep-node');
      expect(keepProfile, isNotNull);
      await provider.activateProfile(keepProfile!.id);

      final removed = await provider.pruneMissingCloudProfiles({
        'Cloud: keep-node',
      });

      expect(removed, 1);
      expect(provider.getProfileByName('Cloud: missing-node'), isNull);
      expect(provider.getProfileByName('Cloud: keep-node'), isNotNull);
      expect(provider.activeProfile?.name, 'Cloud: keep-node');
    });

    test('createProfile rejects reserved cloud prefix by default', () async {
      final provider = ProfileProvider();

      final success = await provider.createProfile(
        name: 'Cloud: manual-node',
        content: '{"outbounds":[]}',
      );

      expect(success, isFalse);
      expect(
        provider.error,
        'Profile names cannot start with "${ProfileProvider.cloudManagedProfilePrefix}"',
      );
      expect(provider.profiles, isEmpty);
    });

    test('createProfile rejects duplicate names after trimming', () async {
      final provider = ProfileProvider();

      final first = await provider.createProfile(
        name: 'Manual A',
        content: '{"outbounds":[]}',
      );
      final second = await provider.createProfile(
        name: '  Manual A  ',
        content: '{"outbounds":[]}',
      );

      expect(first, isTrue);
      expect(second, isFalse);
      expect(provider.error, 'A profile with this name already exists');
      expect(provider.profiles, hasLength(1));
    });

    test('updateProfile rejects duplicate names', () async {
      final provider = ProfileProvider();

      await provider.createProfile(
        name: 'Manual A',
        content: '{"outbounds":[]}',
      );
      await provider.createProfile(
        name: 'Manual B',
        content: '{"outbounds":[]}',
      );
      final profile = provider.getProfileByName('Manual B');

      final success = await provider.updateProfile(
        id: profile!.id,
        name: ' Manual A ',
      );

      expect(success, isFalse);
      expect(provider.error, 'A profile with this name already exists');
      expect(provider.getProfileByName('Manual B'), isNotNull);
    });
  });
}
