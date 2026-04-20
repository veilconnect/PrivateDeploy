import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cloud_models.dart';

String? buildCloudNodeConfig(
  CloudInstance instance, {
  String? preferredEndpointLabel,
  TargetPlatform? targetPlatform,
}) {
  if (!instance.hasIp || instance.nodeInfo == null) {
    return null;
  }

  final ip = instance.ipv4!;
  final info = instance.nodeInfo!;
  final label = instance.label;
  final isAndroid = targetPlatform == TargetPlatform.android;
  final outbounds = <Map<String, dynamic>>[];
  final tags = <String>[];
  final endpointTagByLabel = <String, String>{};

  if (info.ssPort > 0 && info.ssPassword.isNotEmpty) {
    final tag = '$label-SS';
    outbounds.add({
      'type': 'shadowsocks',
      'tag': tag,
      'server': ip,
      'server_port': info.ssPort,
      'method': 'aes-256-gcm',
      'password': info.ssPassword,
    });
    tags.add(tag);
    endpointTagByLabel['Shadowsocks'] = tag;
  }

  if (!isAndroid && info.hyPort > 0 && info.hyPassword.isNotEmpty) {
    final tag = '$label-Hy2';
    outbounds.add({
      'type': 'hysteria2',
      'tag': tag,
      'server': ip,
      'server_port': info.hyPort,
      'up_mbps': 100,
      'down_mbps': 100,
      'password': info.hyPassword,
      'tls': {
        'enabled': true,
        'server_name': info.hyServerName.isNotEmpty ? info.hyServerName : ip,
        'insecure': info.hyInsecure ?? true,
      },
    });
    tags.add(tag);
    endpointTagByLabel['Hysteria2'] = tag;
  }

  if (!isAndroid &&
      info.vlessPort > 0 &&
      info.vlessUuid.isNotEmpty &&
      info.vlessPublicKey.isNotEmpty &&
      info.vlessShortId.isNotEmpty) {
    final tag = '$label-VLESS';
    final publicKeyUrlSafe = info.vlessPublicKey
        .replaceAll('+', '-')
        .replaceAll('/', '_')
        .replaceAll(RegExp(r'=+$'), '');

    outbounds.add({
      'type': 'vless',
      'tag': tag,
      'server': ip,
      'server_port': info.vlessPort,
      'uuid': info.vlessUuid,
      'flow': 'xtls-rprx-vision',
      'tls': {
        'enabled': true,
        'server_name': info.vlessServerName.isNotEmpty
            ? info.vlessServerName
            : 'www.microsoft.com',
        'utls': {
          'enabled': true,
          'fingerprint': 'chrome',
        },
        'reality': {
          'enabled': true,
          'public_key': publicKeyUrlSafe,
          'short_id': info.vlessShortId,
        },
      },
    });
    tags.add(tag);
    endpointTagByLabel['VLESS'] = tag;
  }

  if (info.trojanPort > 0 && info.trojanPassword.isNotEmpty) {
    final tag = '$label-Trojan';
    outbounds.add({
      'type': 'trojan',
      'tag': tag,
      'server': ip,
      'server_port': info.trojanPort,
      'password': info.trojanPassword,
      'tls': {
        'enabled': true,
        'server_name':
            info.trojanServerName.isNotEmpty ? info.trojanServerName : ip,
        'insecure': info.trojanInsecure ?? true,
      },
    });
    tags.add(tag);
    endpointTagByLabel['Trojan'] = tag;
  }

  if (outbounds.isEmpty) {
    return null;
  }

  final preferredTag = endpointTagByLabel[preferredEndpointLabel?.trim() ?? ''];
  final shouldIgnorePreferredEndpoint =
      isAndroid &&
      info.ssPort > 0 &&
      info.ssPassword.isNotEmpty &&
      preferredEndpointLabel?.trim().isNotEmpty == true &&
      preferredEndpointLabel?.trim() != 'Shadowsocks';
  final effectivePreferredTag =
      shouldIgnorePreferredEndpoint ? null : preferredTag;
  if (effectivePreferredTag != null) {
    outbounds.sort((a, b) {
      final aTag = a['tag']?.toString();
      final bTag = b['tag']?.toString();
      if (aTag == effectivePreferredTag && bTag != effectivePreferredTag) {
        return -1;
      }
      if (aTag != effectivePreferredTag && bTag == effectivePreferredTag) {
        return 1;
      }
      return 0;
    });
    tags
      ..remove(effectivePreferredTag)
      ..insert(0, effectivePreferredTag);
  }

  final config = {
    // sing-box client log level. 'warn' silences per-connection
    // outbound/inbound INFO chatter (which dominated logcat for any normal
    // browsing session) while still surfacing real failures.
    'log': {'level': 'warn'},
    'dns': {
      'servers': [
        {
          'tag': 'dns-remote',
          // libbox/sing-box v1.11 still uses the legacy DNS server syntax, so
          // we can't set a separate TLS server_name here. Use Cloudflare's
          // IP-literal DoH endpoint to avoid recursively bootstrapping the DNS
          // server hostname through another resolver on Android.
          'address': 'https://1.1.1.1/dns-query',
          'detour': 'select',
        },
        {
          'tag': 'dns-remote-doh',
          'address': 'https://1.1.1.1/dns-query',
          'detour': 'select',
        },
        // Cloud-provider API lookups must resolve via the underlying network
        // rather than dns-local: sing-box's local resolver opens sockets via
        // the Go runtime which on Android re-enters the TUN (auto_route),
        // producing "context canceled" for these specific queries.
        {
          'tag': 'dns-direct',
          'address': '8.8.8.8',
          'detour': 'direct',
        },
        {
          'tag': 'dns-local',
          'address': 'local',
          'detour': 'direct',
        },
      ],
      'rules': [
        {
          'domain_suffix': ['api.vultr.com', 'api.digitalocean.com'],
          'server': 'dns-direct',
        },
        {
          'outbound': ['any'],
          'server': 'dns-remote',
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
        'default': tags.first,
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
        // Cloud-provider management APIs must bypass the tunnel so the user
        // can still validate/refresh API keys while VPN is connected.
        // Otherwise requests egress via the proxy node, whose path to these
        // endpoints is often slow enough to hit the 12s timeout.
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
