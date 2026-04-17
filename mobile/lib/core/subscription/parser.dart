import 'dart:convert';

/// Subscription URL parser
/// Fetches subscription URL, detects format, parses proxy nodes,
/// and generates sing-box JSON configuration.
class SubscriptionParser {
  /// Parse raw subscription content into sing-box JSON config
  static String? parseToSingboxConfig(String raw) {
    final trimmed = raw.trim();

    // 1. Try as sing-box JSON directly
    if (_isSingboxJson(trimmed)) {
      return trimmed;
    }

    // 2. Try base64 decode → URI list
    final decoded = _tryBase64Decode(trimmed);
    if (decoded != null) {
      final nodes = _parseUriList(decoded);
      if (nodes.isNotEmpty) {
        return _generateSingboxConfig(nodes);
      }
    }

    // 3. Try as plain URI list (one per line)
    final nodes = _parseUriList(trimmed);
    if (nodes.isNotEmpty) {
      return _generateSingboxConfig(nodes);
    }

    return null;
  }

  /// Parse fetched HTTP response data into sing-box JSON config.
  ///
  /// Dio will decode `application/json` responses into Dart objects by default,
  /// so URL imports need a normalization step before handing the payload to the
  /// existing string parser.
  static String? parseResponseDataToSingboxConfig(dynamic data) {
    final raw = _responseDataToRawString(data);
    if (raw == null) {
      return null;
    }
    return parseToSingboxConfig(raw);
  }

  static bool _isSingboxJson(String s) {
    try {
      final json = jsonDecode(s);
      if (json is Map<String, dynamic>) {
        return json.containsKey('outbounds') || json.containsKey('inbounds');
      }
    } catch (_) {}
    return false;
  }

  static String? _responseDataToRawString(dynamic data) {
    if (data == null) {
      return null;
    }
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      try {
        return utf8.decode(data);
      } catch (_) {
        return null;
      }
    }
    if (data is Map || data is List) {
      try {
        return jsonEncode(data);
      } catch (_) {
        return null;
      }
    }
    return data.toString();
  }

  static String? _tryBase64Decode(String s) {
    try {
      // Remove whitespace and padding issues
      var clean = s.replaceAll(RegExp(r'\s'), '');
      // Add padding if needed
      while (clean.length % 4 != 0) {
        clean += '=';
      }
      final decoded = utf8.decode(base64Decode(clean));
      // Verify it looks like URI list
      if (decoded.contains('://')) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  static List<ProxyNode> _parseUriList(String content) {
    final lines = content.split(RegExp(r'[\r\n]+'));
    final nodes = <ProxyNode>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final node = _parseUri(trimmed);
      if (node != null) {
        nodes.add(node);
      }
    }
    return nodes;
  }

  static ProxyNode? _parseUri(String uri) {
    if (uri.startsWith('ss://')) return _parseShadowsocks(uri);
    if (uri.startsWith('vless://')) return _parseVless(uri);
    if (uri.startsWith('trojan://')) return _parseTrojan(uri);
    if (uri.startsWith('hysteria2://') || uri.startsWith('hy2://'))
      return _parseHysteria2(uri);
    if (uri.startsWith('vmess://')) return _parseVmess(uri);
    return null;
  }

  /// Parse ss://method:password@host:port#name
  /// or ss://base64(method:password)@host:port#name
  static ProxyNode? _parseShadowsocks(String uri) {
    try {
      var body = uri.substring(5); // remove ss://

      // Extract fragment (name)
      String? name;
      final hashIdx = body.lastIndexOf('#');
      if (hashIdx >= 0) {
        name = Uri.decodeComponent(body.substring(hashIdx + 1));
        body = body.substring(0, hashIdx);
      }

      String method, password, host;
      int port;

      if (body.contains('@')) {
        final atIdx = body.lastIndexOf('@');
        final userInfo = body.substring(0, atIdx);
        final hostPort = body.substring(atIdx + 1);

        // Parse host:port
        final hp = _parseHostPort(hostPort);
        if (hp == null) return null;
        host = hp.$1;
        port = hp.$2;

        // Try base64 decode userInfo
        String decoded;
        try {
          var clean = userInfo;
          while (clean.length % 4 != 0) clean += '=';
          decoded = utf8.decode(base64Decode(clean));
        } catch (_) {
          decoded = userInfo;
        }

        final colonIdx = decoded.indexOf(':');
        if (colonIdx < 0) return null;
        method = decoded.substring(0, colonIdx);
        password = decoded.substring(colonIdx + 1);
      } else {
        // Entire body is base64
        String decoded;
        try {
          var clean = body;
          while (clean.length % 4 != 0) clean += '=';
          decoded = utf8.decode(base64Decode(clean));
        } catch (_) {
          return null;
        }
        final match = RegExp(r'^(.+?):(.+?)@(.+):(\d+)$').firstMatch(decoded);
        if (match == null) return null;
        method = match.group(1)!;
        password = match.group(2)!;
        host = match.group(3)!;
        port = int.parse(match.group(4)!);
      }

      return ProxyNode(
        type: 'shadowsocks',
        name: name ?? 'SS $host:$port',
        server: host,
        port: port,
        extra: {
          'method': method,
          'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse vless://uuid@host:port?params#name
  static ProxyNode? _parseVless(String uri) {
    try {
      final parsed = Uri.parse(uri);
      final uuid = parsed.userInfo;
      final host = parsed.host;
      final port = parsed.port;
      final name =
          parsed.fragment.isNotEmpty ? parsed.fragment : 'VLESS $host:$port';
      final params = parsed.queryParameters;

      return ProxyNode(
        type: 'vless',
        name: name,
        server: host,
        port: port,
        extra: {
          'uuid': uuid,
          'flow': params['flow'] ?? '',
          'security': params['security'] ?? 'none',
          'sni': params['sni'] ?? '',
          'pbk': params['pbk'] ?? '',
          'sid': params['sid'] ?? '',
          'type': params['type'] ?? 'tcp',
          'fp': params['fp'] ?? '',
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse trojan://password@host:port?params#name
  static ProxyNode? _parseTrojan(String uri) {
    try {
      final parsed = Uri.parse(uri);
      final password = parsed.userInfo;
      final host = parsed.host;
      final port = parsed.port;
      final name =
          parsed.fragment.isNotEmpty ? parsed.fragment : 'Trojan $host:$port';
      final params = parsed.queryParameters;

      return ProxyNode(
        type: 'trojan',
        name: name,
        server: host,
        port: port,
        extra: {
          'password': password,
          'sni': params['sni'] ?? host,
          'insecure': params['allowInsecure'] ?? params['insecure'] ?? '0',
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse hysteria2://password@host:port?params#name
  static ProxyNode? _parseHysteria2(String uri) {
    try {
      final parsed = Uri.parse(uri.replaceFirst('hy2://', 'hysteria2://'));
      final password = parsed.userInfo;
      final host = parsed.host;
      final port = parsed.port;
      final name =
          parsed.fragment.isNotEmpty ? parsed.fragment : 'Hy2 $host:$port';
      final params = parsed.queryParameters;

      return ProxyNode(
        type: 'hysteria2',
        name: name,
        server: host,
        port: port,
        extra: {
          'password': password,
          'sni': params['sni'] ?? host,
          'insecure': params['insecure'] ?? '0',
          if (params['up_mbps'] != null) 'up_mbps': params['up_mbps'],
          if (params['down_mbps'] != null) 'down_mbps': params['down_mbps'],
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse vmess://base64json
  static ProxyNode? _parseVmess(String uri) {
    try {
      var body = uri.substring(8); // remove vmess://
      while (body.length % 4 != 0) body += '=';
      final decoded = utf8.decode(base64Decode(body));
      final json = jsonDecode(decoded) as Map<String, dynamic>;

      return ProxyNode(
        type: 'vmess',
        name: json['ps']?.toString() ?? 'VMess ${json['add']}:${json['port']}',
        server: json['add']?.toString() ?? '',
        port: int.tryParse(json['port'].toString()) ?? 0,
        extra: {
          'uuid': json['id']?.toString() ?? '',
          'alterId': int.tryParse(json['aid'].toString()) ?? 0,
          'security': json['scy']?.toString() ?? 'auto',
          'network': json['net']?.toString() ?? 'tcp',
          'tls': json['tls']?.toString() ?? '',
          'sni': json['sni']?.toString() ?? json['host']?.toString() ?? '',
        },
      );
    } catch (_) {
      return null;
    }
  }

  static (String, int)? _parseHostPort(String s) {
    // Handle [ipv6]:port
    if (s.startsWith('[')) {
      final closeIdx = s.indexOf(']');
      if (closeIdx < 0) return null;
      final host = s.substring(1, closeIdx);
      final portStr = s.substring(closeIdx + 2); // skip ]:
      return (host, int.tryParse(portStr) ?? 0);
    }
    final colonIdx = s.lastIndexOf(':');
    if (colonIdx < 0) return null;
    return (
      s.substring(0, colonIdx),
      int.tryParse(s.substring(colonIdx + 1)) ?? 0
    );
  }

  /// Generate sing-box JSON config from parsed nodes
  static String _generateSingboxConfig(List<ProxyNode> nodes) {
    final outbounds = <Map<String, dynamic>>[];
    final tags = <String>[];

    for (final node in nodes) {
      final outbound = _nodeToOutbound(node);
      if (outbound != null) {
        outbounds.add(outbound);
        tags.add(outbound['tag'] as String);
      }
    }

    if (outbounds.isEmpty) return '{}';

    // Add selector and urltest
    final config = {
      // sing-box client log level. 'warn' silences per-connection
      // outbound/inbound INFO chatter (which produced ~4 logcat lines per TCP
      // connection, dominating logcat for any normal browsing session) while
      // still surfacing real failures.
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {
            'tag': 'dns-remote',
            'address': '8.8.8.8',
            'detour': 'select',
          },
          {
            'tag': 'dns-remote-doh',
            'address': 'https://8.8.8.8/dns-query',
            'detour': 'select',
          },
          {
            'tag': 'dns-direct',
            'address': '8.8.8.8',
            'detour': 'direct',
          },
          {'tag': 'dns-local', 'address': 'local'},
        ],
        'rules': [
          {
            'domain_suffix': ['api.vultr.com', 'api.digitalocean.com'],
            'server': 'dns-direct',
          },
          {
            'outbound': ['any'],
            'server': 'dns-local',
          },
        ],
        'strategy': 'prefer_ipv4',
        'independent_cache': true,
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'tun0',
          'inet4_address': '172.19.0.1/30',
          'auto_route': true,
          'strict_route': true,
          'stack': 'system',
          'sniff': true,
        },
      ],
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': ['auto', ...tags],
          'default': 'auto',
        },
        {
          'type': 'urltest',
          'tag': 'auto',
          'outbounds': tags,
          'url': 'http://www.gstatic.com/generate_204',
          'interval': '5m',
          'tolerance': 200,
          'idle_timeout': '30m',
        },
        ...outbounds,
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'dns', 'tag': 'dns-out'},
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {
        'rules': [
          {'protocol': 'dns', 'outbound': 'dns-out'},
          {
            'geoip': ['private'],
            'outbound': 'direct'
          },
          {
            'domain_suffix': ['api.vultr.com', 'api.digitalocean.com'],
            'outbound': 'direct',
          },
        ],
        'auto_detect_interface': true,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  static Map<String, dynamic>? _nodeToOutbound(ProxyNode node) {
    switch (node.type) {
      case 'shadowsocks':
        return {
          'type': 'shadowsocks',
          'tag': node.name,
          'server': node.server,
          'server_port': node.port,
          'method': node.extra['method'] ?? 'aes-256-gcm',
          'password': node.extra['password'] ?? '',
        };

      case 'vless':
        final security = node.extra['security'] ?? 'none';
        final out = <String, dynamic>{
          'type': 'vless',
          'tag': node.name,
          'server': node.server,
          'server_port': node.port,
          'uuid': node.extra['uuid'] ?? '',
        };
        if ((node.extra['flow'] ?? '').isNotEmpty) {
          out['flow'] = node.extra['flow'];
        }
        if (security == 'reality') {
          out['tls'] = {
            'enabled': true,
            'server_name': node.extra['sni'] ?? '',
            'utls': {
              'enabled': true,
              'fingerprint': node.extra['fp'] ?? 'chrome'
            },
            'reality': {
              'enabled': true,
              'public_key': node.extra['pbk'] ?? '',
              'short_id': node.extra['sid'] ?? '',
            },
          };
        } else if (security == 'tls') {
          out['tls'] = {
            'enabled': true,
            'server_name': node.extra['sni'] ?? '',
          };
        }
        return out;

      case 'trojan':
        return {
          'type': 'trojan',
          'tag': node.name,
          'server': node.server,
          'server_port': node.port,
          'password': node.extra['password'] ?? '',
          'tls': {
            'enabled': true,
            'server_name': node.extra['sni'] ?? node.server,
            'insecure': node.extra['insecure'] == '1',
          },
        };

      case 'hysteria2':
        final upMbps = int.tryParse(
                node.extra['up_mbps']?.toString() ?? '') ??
            100;
        final downMbps = int.tryParse(
                node.extra['down_mbps']?.toString() ?? '') ??
            100;
        return {
          'type': 'hysteria2',
          'tag': node.name,
          'server': node.server,
          'server_port': node.port,
          'up_mbps': upMbps,
          'down_mbps': downMbps,
          'password': node.extra['password'] ?? '',
          'tls': {
            'enabled': true,
            'server_name': node.extra['sni'] ?? node.server,
            'insecure': node.extra['insecure'] == '1',
          },
        };

      case 'vmess':
        final out = <String, dynamic>{
          'type': 'vmess',
          'tag': node.name,
          'server': node.server,
          'server_port': node.port,
          'uuid': node.extra['uuid'] ?? '',
          'alter_id': node.extra['alterId'] ?? 0,
          'security': node.extra['security'] ?? 'auto',
        };
        if (node.extra['tls'] == 'tls') {
          out['tls'] = {
            'enabled': true,
            'server_name': node.extra['sni'] ?? '',
          };
        }
        return out;

      default:
        return null;
    }
  }
}

class ProxyNode {
  final String type; // shadowsocks, vless, trojan, hysteria2, vmess
  final String name;
  final String server;
  final int port;
  final Map<String, dynamic> extra;

  ProxyNode({
    required this.type,
    required this.name,
    required this.server,
    required this.port,
    this.extra = const {},
  });
}
