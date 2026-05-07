import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/network/managed_dns_defaults.dart';
import 'cloud_models.dart';

const Map<String, String> _cloudEndpointLabelByTagSuffix = {
  '-SS': 'Shadowsocks',
  '-Trojan': 'Trojan',
  '-VLESS': 'VLESS',
  '-Hy2': 'Hysteria2',
};

List<String> availableCloudEndpointLabels(NodeInfo? info) {
  if (info == null) {
    return const [];
  }

  final labels = <String>[];
  if (info.ssPort > 0 && info.ssPassword.isNotEmpty) {
    labels.add('Shadowsocks');
  }
  if (info.hyPort > 0 && info.hyPassword.isNotEmpty) {
    labels.add('Hysteria2');
  }
  if (info.vlessPort > 0 &&
      info.vlessUuid.isNotEmpty &&
      info.vlessPublicKey.isNotEmpty &&
      info.vlessShortId.isNotEmpty) {
    labels.add('VLESS');
  }
  if (info.trojanPort > 0 && info.trojanPassword.isNotEmpty) {
    labels.add('Trojan');
  }
  return labels;
}

String? activeCloudNodeEndpointLabel(String? rawConfig) {
  if (rawConfig == null || rawConfig.trim().isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(rawConfig);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final outbounds = decoded['outbounds'];
    if (outbounds is! List) {
      return null;
    }

    final selector =
        outbounds.whereType<Map>().cast<Map<String, dynamic>>().firstWhere(
              (item) => item['type'] == 'selector' && item['tag'] == 'select',
              orElse: () => const <String, dynamic>{},
            );
    final defaultTag = selector['default']?.toString().trim();
    return _cloudEndpointLabelFromTag(defaultTag);
  } catch (_) {
    return null;
  }
}

String? _cloudEndpointLabelFromTag(String? tag) {
  if (tag == null || tag.isEmpty || tag == 'auto') {
    return null;
  }
  for (final entry in _cloudEndpointLabelByTagSuffix.entries) {
    if (tag.endsWith(entry.key)) {
      return entry.value;
    }
  }
  return switch (tag) {
    'Shadowsocks' || 'Trojan' || 'VLESS' || 'Hysteria2' => tag,
    _ => null,
  };
}

/// Append all viable protocol outbounds for [instance] into [outbounds] and
/// their tags into [tags]. Mirrors the per-protocol blocks the active node
/// uses, so a failover node ends up with the same shape (including the
/// optional CDN-fronted variant). Returns the protocol→tag map for the
/// instance, used by the active node's preferred-endpoint selector.
Map<String, String> _appendInstanceOutbounds(
  CloudInstance instance, {
  required List<Map<String, dynamic>> outbounds,
  required List<String> tags,
  String? cdnWorkerHost,
}) {
  final endpointTagByLabel = <String, String>{};
  final info = instance.nodeInfo;
  if (info == null || !instance.hasIp) {
    return endpointTagByLabel;
  }
  final ip = instance.ipv4!;
  final label = instance.label;

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
    endpointTagByLabel['Hysteria2'] = tag;
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
    endpointTagByLabel['VLESS'] = tag;
  }

  // CDN-fronted variant. Routed to a Cloudflare Worker host that relays
  // WS↔TCP to the node's vlessRelayPort. Only added when both the worker
  // host is provided AND the node has the relay port (older deploys lack
  // it and would yield a non-functional outbound).
  if (cdnWorkerHost != null &&
      cdnWorkerHost.isNotEmpty &&
      info.vlessRelayPort > 0 &&
      info.vlessUuid.isNotEmpty) {
    final tag = '$label-CDN';
    outbounds.add({
      'type': 'vless',
      'tag': tag,
      'server': cdnWorkerHost,
      'server_port': 443,
      'uuid': info.vlessUuid,
      'transport': {
        'type': 'ws',
        'path': '/?ed=2560',
        'headers': {'Host': cdnWorkerHost},
      },
      'tls': {
        'enabled': true,
        'server_name': cdnWorkerHost,
        'utls': {
          'enabled': true,
          'fingerprint': 'chrome',
        },
      },
    });
    tags.add(tag);
    endpointTagByLabel['CDN'] = tag;
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

  return endpointTagByLabel;
}

String? buildCloudNodeConfig(
  CloudInstance instance, {
  String? preferredEndpointLabel,
  TargetPlatform? targetPlatform,
  // When non-null, append a CDN-fronted VLESS variant pointing at this
  // Cloudflare Worker host. The Worker is expected to relay WS frames to the
  // node's vlessRelayPort over plain TCP — see docs/cdn-acceleration. The
  // CDN variant joins the urltest pool so sing-box auto-fails over from
  // direct → CDN when the carrier blocks the direct path.
  String? cdnWorkerHost,
  // Other cloud nodes to enroll in the same urltest failover pool. When the
  // active node's IP is dropped by the carrier (e.g. mobile carrier silently
  // blackholing some VPS ranges on cellular), sing-box urltest will pick a
  // working failover node automatically. Failover only applies in "auto"
  // mode — if [preferredEndpointLabel] pins a protocol, the user explicitly
  // wants that one outbound and we honor it.
  List<CloudInstance> failoverInstances = const [],
  // Resolves the CDN worker host for any instance in [failoverInstances].
  // The active instance keeps the simpler [cdnWorkerHost] for back-compat.
  String? Function(CloudInstance instance)? failoverCdnWorkerHostResolver,
}) {
  if (!instance.hasIp || instance.nodeInfo == null) {
    return null;
  }

  final outbounds = <Map<String, dynamic>>[];
  final tags = <String>[];
  final endpointTagByLabel = _appendInstanceOutbounds(
    instance,
    outbounds: outbounds,
    tags: tags,
    cdnWorkerHost: cdnWorkerHost,
  );

  if (outbounds.isEmpty) {
    return null;
  }

  final preferredTag = endpointTagByLabel[preferredEndpointLabel?.trim() ?? ''];
  if (preferredTag != null) {
    outbounds.sort((a, b) {
      final aTag = a['tag']?.toString();
      final bTag = b['tag']?.toString();
      if (aTag == preferredTag && bTag != preferredTag) {
        return -1;
      }
      if (aTag != preferredTag && bTag == preferredTag) {
        return 1;
      }
      return 0;
    });
    tags
      ..remove(preferredTag)
      ..insert(0, preferredTag);
  }
  final manualProtocolSelection = preferredTag != null;

  // Failover instances: only enrolled when in auto mode. Tag conflicts (two
  // instances with the same label) are skipped — the second occurrence is
  // dropped rather than ambiguously routed.
  final failoverOutbounds = <Map<String, dynamic>>[];
  final failoverTags = <String>[];
  if (!manualProtocolSelection) {
    final activeTagSet = tags.toSet();
    for (final fi in failoverInstances) {
      if (fi.id == instance.id) continue;
      if (!fi.hasIp || fi.nodeInfo == null) continue;
      final scratchOutbounds = <Map<String, dynamic>>[];
      final scratchTags = <String>[];
      _appendInstanceOutbounds(
        fi,
        outbounds: scratchOutbounds,
        tags: scratchTags,
        cdnWorkerHost: failoverCdnWorkerHostResolver?.call(fi),
      );
      for (var i = 0; i < scratchTags.length; i++) {
        final tag = scratchTags[i];
        if (activeTagSet.contains(tag) || failoverTags.contains(tag)) continue;
        failoverTags.add(tag);
        failoverOutbounds.add(scratchOutbounds[i]);
      }
    }
  }

  final allUrlTestTags = <String>[...tags, ...failoverTags];
  final protocolOutbounds = manualProtocolSelection
      ? outbounds
          .where((outbound) => outbound['tag']?.toString() == preferredTag)
          .toList(growable: false)
      : <Map<String, dynamic>>[...outbounds, ...failoverOutbounds];
  final selectorOutbounds = manualProtocolSelection
      ? List<String>.from(tags.take(1))
      : ['auto', ...allUrlTestTags];
  final includeUrlTest = !manualProtocolSelection;

  final config = {
    // Keep per-connection INFO logs available so the diagnostics screen can
    // reconstruct recent DIRECT/PROXY decisions from runtime traffic.
    // Android filters these out of logcat at the service layer to avoid
    // restoring the old log spam problem.
    'log': {'level': 'info'},
    'dns': {
      'servers': [
        {
          'tag': managedDnsRemoteTag,
          // libbox/sing-box v1.11 still uses the legacy DNS server syntax, so
          // we can't set a separate TLS server_name here. Use Cloudflare's
          // IP-literal DoH endpoint to avoid recursively bootstrapping the DNS
          // server hostname through another resolver on Android.
          'address': managedDnsRemoteAddress,
          'detour': 'select',
        },
        {
          'tag': managedDnsRemoteFallbackTag,
          'address': managedDnsRemoteFallbackAddress,
          'detour': 'select',
        },
        // Cloud-provider API lookups must resolve via the underlying network
        // rather than dns-local: sing-box's local resolver opens sockets via
        // the Go runtime which on Android re-enters the TUN (auto_route),
        // producing "context canceled" for these specific queries.
        {
          'tag': managedDnsBootstrapTag,
          'address': managedDnsBootstrapAddress,
          'detour': 'direct',
        },
        {
          'tag': managedDnsCnTag,
          'address': managedDnsCnAddress,
          'detour': 'direct',
        },
        {
          'tag': managedDnsLocalTag,
          'address': 'local',
          'detour': 'direct',
        },
      ],
      'rules': [
        {
          'domain_suffix': ['api.vultr.com', 'api.digitalocean.com'],
          'server': managedDnsBootstrapTag,
        },
        {
          'domain_suffix': managedDnsRemoteFallbackDomainSuffixes,
          'server': managedDnsRemoteFallbackTag,
        },
        {
          'outbound': ['any'],
          'server': managedDnsRemoteTag,
        },
      ],
      'strategy': 'prefer_ipv4',
      'reverse_mapping': true,
      'cache_capacity': managedDnsCacheCapacity,
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
        // Cloud profiles should keep Android's system TUN stack so mobile
        // networks can continue using platform features such as 464XLAT/NAT64
        // when the device leaves Wi-Fi and falls back to cellular.
        'stack': 'system',
        'sniff': true,
      },
    ],
    'outbounds': [
      {
        'type': 'selector',
        'tag': 'select',
        'interrupt_exist_connections': true,
        'outbounds': selectorOutbounds,
        'default': manualProtocolSelection ? tags.first : 'auto',
      },
      if (includeUrlTest)
        {
          'type': 'urltest',
          'tag': 'auto',
          'interrupt_exist_connections': true,
          'outbounds': allUrlTestTags,
          // IP-literal so the urltest probe never has to resolve a hostname.
          // The DNS module's "any" rule routes through dns-remote (DoH 1.1.1.1)
          // with detour: select → auto → urltest's first member. If that
          // member is unreachable (carrier blocking the VPS IP, captive
          // portal, etc.) DNS hangs, no probe ever fires, and urltest can't
          // discover the working failover member it already has in pool.
          // 1.0.0.1 is Cloudflare's anycast resolver; /cdn-cgi/trace returns
          // a small 200 OK so any 2xx counts as reachable for urltest.
          'url': 'http://1.0.0.1/cdn-cgi/trace',
          'interval': '5m',
          'tolerance': 200,
        },
      ...protocolOutbounds,
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
      // Android relies on libbox's platform socket protection to keep proxy
      // outbounds off the VPN TUN. The mobile core now avoids the old
      // extra bind-to-interface path while preserving that protection, so
      // keep auto-detect enabled here.
      'auto_detect_interface': true,
      // When Wi-Fi drops and Android promotes cellular to the default
      // network, sing-box must follow that new default explicitly for its
      // upstream proxy sockets. Otherwise the VPN can stay "connected" while
      // outbound dials still fail on the stale path.
      'default_network_strategy': 'default',
    },
  };

  return const JsonEncoder.withIndent('  ').convert(config);
}
