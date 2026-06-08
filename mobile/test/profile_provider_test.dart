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

    test(
        'normalizeConfigForCurrentPlatform preserves explicit Android system tun stack',
        () {
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
      expect((inbounds.first as Map<String, dynamic>)['stack'], 'system');
    });

    test('normalizeConfigForCurrentPlatform fills missing Android tun stack',
        () {
      const config = '''
{
  "inbounds": [
    {
      "type": "tun"
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
        'normalizeConfigForCurrentPlatform rewrites proxy-import Android system stack to gvisor',
        () {
      const config = '''
{
  "log": {
    "level": "warn"
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "select"
      },
      {
        "tag": "dns-direct",
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-1"],
      "default": "node-1"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-1"],
      "url": "http://www.gstatic.com/generate_204"
    },
    {
      "type": "shadowsocks",
      "tag": "node-1",
      "server": "1.2.3.4",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "test"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ],
    "auto_detect_interface": true
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      expect((json['log'] as Map<String, dynamic>)['level'], 'info');
      final inbounds = json['inbounds'] as List<dynamic>;
      expect((inbounds.first as Map<String, dynamic>)['stack'], 'gvisor');
      final route = json['route'] as Map<String, dynamic>;
      expect(route['auto_detect_interface'], isTrue);
      final outbounds = json['outbounds'] as List<dynamic>;
      final selector = outbounds.firstWhere(
        (outbound) => (outbound as Map<String, dynamic>)['type'] == 'selector',
      ) as Map<String, dynamic>;
      expect(selector['default'], 'auto');
    });

    test(
        'normalizeConfigForCurrentPlatform rewrites legacy Android cloud gvisor stack to system',
        () {
      const config = '''
{
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "select"
      },
      {
        "tag": "dns-direct",
        "address": "https://1.12.12.12/dns-query",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["api.vultr.com", "api.digitalocean.com"],
        "server": "dns-direct"
      },
      {
        "outbound": ["any"],
        "server": "dns-remote"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "gvisor",
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-1-SS", "node-1-Trojan"],
      "default": "node-1-SS"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-1-SS", "node-1-Trojan"],
      "url": "http://www.gstatic.com/generate_204"
    },
    {
      "type": "shadowsocks",
      "tag": "node-1-SS",
      "server": "1.2.3.4",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "test"
    },
    {
      "type": "trojan",
      "tag": "node-1-Trojan",
      "server": "1.2.3.4",
      "server_port": 443,
      "password": "test",
      "tls": {
        "enabled": true,
        "server_name": "1.2.3.4",
        "insecure": true
      }
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
        "domain_suffix": ["api.vultr.com", "api.digitalocean.com"],
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final inbounds = json['inbounds'] as List<dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final outbounds =
          (json['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((item) => item['tag'] == 'select');
      final urltest = outbounds.firstWhere((item) => item['tag'] == 'auto');
      expect((inbounds.first as Map<String, dynamic>)['stack'], 'system');
      expect(route['default_network_strategy'], 'default');
      expect(selector['interrupt_exist_connections'], isTrue);
      expect(urltest['interrupt_exist_connections'], isTrue);
      expect(urltest.containsKey('idle_timeout'), isFalse);
    });

    test(
        'normalizeConfigForCurrentPlatform resolves proxy server domains via dns-direct',
        () {
      const config = '''
{
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "select"
      },
      {
        "tag": "dns-direct",
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": ["any"],
        "server": "dns-remote"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "stack": "gvisor"
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-1"],
      "default": "node-1"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-1"],
      "url": "http://www.gstatic.com/generate_204"
    },
    {
      "type": "shadowsocks",
      "tag": "node-1",
      "server": "edge.example.com",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "test"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ],
    "auto_detect_interface": true
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final dns = json['dns'] as Map<String, dynamic>;
      final dnsRules =
          (dns['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      final dnsServers =
          (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        dnsRules.firstWhere(
          (rule) =>
              rule['server'] == 'dns-direct' && rule.containsKey('domain'),
        ),
        {
          'domain': ['edge.example.com'],
          'server': 'dns-direct',
        },
      );
      expect(
        dnsRules.indexWhere(
          (rule) =>
              rule['server'] == 'dns-direct' && rule.containsKey('domain'),
        ),
        lessThan(
          dnsRules.indexWhere(
            (rule) =>
                (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
          ),
        ),
      );
      expect(
        dnsServers.any(
          (server) =>
              server['tag'] == 'dns-direct' &&
              server['address'] == 'https://1.12.12.12/dns-query',
        ),
        isTrue,
      );
      expect(
        dnsServers.any(
          (server) =>
              server['tag'] == 'dns-remote-google' &&
              server['address'] == 'https://8.8.8.8/dns-query',
        ),
        isTrue,
      );

      final route = json['route'] as Map<String, dynamic>;
      final routeRules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        routeRules.firstWhere(
          (rule) => rule['outbound'] == 'direct' && rule.containsKey('domain'),
        ),
        {
          'domain': ['edge.example.com'],
          'outbound': 'direct',
        },
      );
    });

    test(
        'normalizeConfigForCurrentPlatform applies China-optimized DNS split rules',
        () {
      const config = '''
{
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "select"
      },
      {
        "tag": "dns-direct",
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": ["any"],
        "server": "dns-remote"
      }
    ]
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-1"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-1"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-1",
      "server": "edge.example.com",
      "server_port": 8388
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
      }
    ]
  }
}
''';

      final normalized = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
        routingSettings: VpnRoutingSettings.defaults.copyWith(
          customDirectDomains: const ['corp.local'],
        ),
        bundledRuleSetPaths: const BundledRuleSetPaths(
          geositeCnPath: '/tmp/geosite-cn.srs',
        ),
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final dns = json['dns'] as Map<String, dynamic>;
      final dnsServers =
          (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>();
      final dnsRules =
          (dns['rules'] as List<dynamic>).cast<Map<String, dynamic>>();

      expect(
        dnsServers.any(
          (server) =>
              server['tag'] == 'dns-cn' &&
              server['address'] == 'https://223.5.5.5/dns-query',
        ),
        isTrue,
      );
      expect(
        dnsRules.any(
          (rule) =>
              rule['server'] == 'dns-cn' &&
              listEquals(
                (rule['domain_suffix'] as List<dynamic>?)?.cast<String>(),
                ['corp.local'],
              ),
        ),
        isTrue,
      );
      expect(
        dnsRules.any(
          (rule) =>
              rule['server'] == 'dns-cn' && rule['rule_set'] == 'pd-geosite-cn',
        ),
        isTrue,
      );
      expect(
        dnsRules.firstWhere(
          (rule) =>
              (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
        )['server'],
        'dns-remote',
      );
      expect(
        dnsRules.any(
          (rule) =>
              rule['server'] == 'dns-remote-google' &&
              (rule['domain_suffix'] as List<dynamic>?)
                      ?.contains('youtube.com') ==
                  true,
        ),
        isTrue,
      );
      expect((dns['cache_capacity'] as int?) ?? 0, 4096);
      expect(dns['reverse_mapping'], isTrue);
    });

    test(
        'normalizeConfigForCurrentPlatform supports strict proxy and system DNS modes',
        () {
      const config = '''
{
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "select"
      },
      {
        "tag": "dns-direct",
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": ["any"],
        "server": "dns-remote"
      }
    ]
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["auto", "node-1"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["node-1"]
    },
    {
      "type": "shadowsocks",
      "tag": "node-1",
      "server": "edge.example.com",
      "server_port": 8388
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
      }
    ]
  }
}
''';

      final strict = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
        routingSettings: VpnRoutingSettings.defaults.copyWith(
          dnsMode: VpnDnsMode.strictProxy,
          customDirectDomains: const ['corp.local'],
        ),
      );
      final strictJson = jsonDecode(strict) as Map<String, dynamic>;
      final strictRules = (((strictJson['dns']
              as Map<String, dynamic>)['rules']) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(
        strictRules.firstWhere(
          (rule) =>
              (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
        )['server'],
        'dns-remote',
      );
      expect(
        strictRules.any((rule) => rule['server'] == 'dns-cn'),
        isFalse,
      );

      final system = ProfileProvider.normalizeConfigForCurrentPlatform(
        config,
        targetPlatform: TargetPlatform.android,
        routingSettings: VpnRoutingSettings.defaults.copyWith(
          dnsMode: VpnDnsMode.systemResolver,
        ),
      );
      final systemJson = jsonDecode(system) as Map<String, dynamic>;
      final systemRules = (((systemJson['dns']
              as Map<String, dynamic>)['rules']) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(
        systemRules.firstWhere(
          (rule) =>
              (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
        )['server'],
        'dns-local',
      );
    });

    test(
        'normalizeConfigForCurrentPlatform blocks Android Private DNS probes before tun routing',
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
                [
                  '127.0.0.0/8',
                  '::1/128',
                  '172.19.0.0/30',
                ],
              ),
        ),
        isTrue,
      );
    });

    test(
        'normalizeConfigForCurrentPlatform preserves Android hysteria2 outbounds',
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
        isNotEmpty,
      );

      final selector = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'select');
      expect(selector['outbounds'], ['auto', 'node-ss', 'node-hy2']);

      final auto = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'auto');
      expect(auto['outbounds'], ['node-ss', 'node-hy2']);
    });

    test(
        'normalizeConfigForCurrentPlatform preserves Android vless reality outbounds',
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
        isNotEmpty,
      );

      final selector = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'select');
      expect(selector['outbounds'],
          ['auto', 'node-ss', 'node-vless', 'node-trojan']);
      expect(selector['default'], 'auto');

      final auto = outbounds
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'auto');
      expect(auto['outbounds'], ['node-ss', 'node-vless', 'node-trojan']);
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

    test(
        'normalizeConfigForCurrentPlatform adds Android China app direct bypass in split mode',
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
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      final inbounds =
          (json['inbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final tunInbound =
          inbounds.firstWhere((inbound) => inbound['type'] == 'tun');
      final excludePackages =
          (tunInbound['exclude_package'] as List<dynamic>?)?.cast<String>() ??
              const <String>[];

      final directPackageRule = rules.firstWhere(
        (rule) =>
            rule['outbound'] == 'direct' && rule.containsKey('package_name'),
      );
      final directPackages =
          (directPackageRule['package_name'] as List<dynamic>).cast<String>();

      expect(directPackages, contains('com.tencent.mm'));
      expect(directPackages, contains('com.eg.android.AlipayGphone'));
      expect(excludePackages, contains('com.tencent.mm'));
      expect(excludePackages, contains('com.eg.android.AlipayGphone'));
    });

    test('normalizeConfigForCurrentPlatform adds custom proxy and direct rules',
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
              ((rule['package_name'] as List<dynamic>?)?.cast<String>() ??
                      const <String>[])
                  .contains('com.example.mail') &&
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

      final inbounds =
          (json['inbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final tunInbound =
          inbounds.firstWhere((inbound) => inbound['type'] == 'tun');
      final excludePackages =
          (tunInbound['exclude_package'] as List<dynamic>?)?.cast<String>() ??
              const <String>[];
      expect(excludePackages, contains('com.example.mail'));
      expect(excludePackages, contains('com.tencent.mm'));
      expect(excludePackages, isNot(contains('com.example.browser')));
    });

    test(
        'normalizeConfigForCurrentPlatform lets custom proxy packages override Android China app direct bypass',
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
          customProxyPackages: ['com.tencent.mm'],
        ),
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      final inbounds =
          (json['inbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final tunInbound =
          inbounds.firstWhere((inbound) => inbound['type'] == 'tun');
      final excludePackages =
          (tunInbound['exclude_package'] as List<dynamic>?)?.cast<String>() ??
              const <String>[];

      final proxyPackageRule = rules.firstWhere(
        (rule) =>
            rule['outbound'] == 'select' && rule.containsKey('package_name'),
      );
      expect(
        (proxyPackageRule['package_name'] as List<dynamic>).cast<String>(),
        contains('com.tencent.mm'),
      );

      final directPackageRule = rules.firstWhere(
        (rule) =>
            rule['outbound'] == 'direct' && rule.containsKey('package_name'),
      );
      expect(
        (directPackageRule['package_name'] as List<dynamic>).cast<String>(),
        isNot(contains('com.tencent.mm')),
      );
      expect(excludePackages, isNot(contains('com.tencent.mm')));
    });

    test(
        'normalizeConfigForCurrentPlatform does not auto-bypass China apps in global mode',
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
        routingSettings: const VpnRoutingSettings(mode: VpnRoutingMode.global),
        targetPlatform: TargetPlatform.android,
      );
      final json = jsonDecode(normalized) as Map<String, dynamic>;
      final route = json['route'] as Map<String, dynamic>;
      final rules =
          (route['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      final inbounds =
          (json['inbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final tunInbound =
          inbounds.firstWhere((inbound) => inbound['type'] == 'tun');
      final excludePackages =
          (tunInbound['exclude_package'] as List<dynamic>?)?.cast<String>() ??
              const <String>[];
      final directPackageRule = rules.where(
        (rule) =>
            rule['outbound'] == 'direct' && rule.containsKey('package_name'),
      );

      expect(
        directPackageRule.any(
          (rule) => ((rule['package_name'] as List<dynamic>?)?.cast<String>() ??
                  const <String>[])
              .contains('com.tencent.mm'),
        ),
        isFalse,
      );
      expect(excludePackages, isNot(contains('com.tencent.mm')));
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
