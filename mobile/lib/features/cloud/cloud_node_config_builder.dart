import 'dart:convert';

import 'cloud_models.dart';

String? buildCloudNodeConfig(CloudInstance instance) {
  if (!instance.hasIp || instance.nodeInfo == null) {
    return null;
  }

  final ip = instance.ipv4!;
  final info = instance.nodeInfo!;
  final label = instance.label;
  final outbounds = <Map<String, dynamic>>[];
  final tags = <String>[];

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
  }

  if (info.hyPort > 0 && info.hyPassword.isNotEmpty) {
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
  }

  if (info.vlessPort > 0 &&
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
  }

  if (outbounds.isEmpty) {
    return null;
  }

  final config = {
    'log': {'level': 'info'},
    'dns': {
      'servers': [
        {
          'tag': 'dns-remote',
          'address': 'https://8.8.8.8/dns-query',
          'detour': 'select',
        },
        {'tag': 'dns-local', 'address': 'local'},
      ],
      'rules': [
        {
          'outbound': ['any'],
          'server': 'dns-local'
        },
      ],
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
        'url': 'https://www.gstatic.com/generate_204',
        'interval': '5m',
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
      ],
      'auto_detect_interface': true,
    },
  };

  return const JsonEncoder.withIndent('  ').convert(config);
}
