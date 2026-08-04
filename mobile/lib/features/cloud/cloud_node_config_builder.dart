import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/network/managed_dns_defaults.dart';
import 'cloud_models.dart';
import 'vultr_deploy.dart' show defaultVlessServerName;

const bool _vpnCoreDebugLogs = bool.fromEnvironment(
  'PRIVATEDEPLOY_VPNCORE_DEBUG_LOGS',
);

/// Stable Cloudflare anycast edge IPs used as DNS-independent CDN entry points
/// when the user hasn't pinned a preferred edge IP. The CDN outbound keeps the
/// custom-domain SNI/Host (so CF routes to the Worker) but dials one of these
/// directly, surviving networks that poison/block DNS for the relay's custom
/// domain. Verified reachable on CN cellular 2026-06-30; refresh if CF rotates.
const List<String> cloudflareEdgeIpFallbacks = <String>[
  '104.16.132.229',
  '172.67.202.217',
];

/// Fully-qualified destination of the CDN-fronted variant for one node.
/// Carries both the hostname (M1 custom domain when bound, falling back to
/// `*.workers.dev`) and the per-deployment PATH_SECRET that the Worker
/// enforces. Without the secret the client is rejected with a generic 404,
/// so the secret is part of the routing identity, not a UI-only field.
@immutable
class CdnEndpoint {
  const CdnEndpoint({
    required this.host,
    this.pathSecret,
    this.fallbackHost,
    this.preferredEdgeIp,
  });

  final String host;

  /// Optional hand-picked Cloudflare edge IP ("preferred edge IP"). When set, the builder
  /// adds an EXTRA CDN outbound that dials this IP directly on :443 while still
  /// presenting [host] as the TLS SNI + WebSocket `Host` header, so CF routes
  /// it to the same Worker. The DNS-resolved custom-host and workers.dev paths
  /// are kept alongside it, so urltest gets independent entry points and can
  /// self-heal when one path is temporarily unhealthy. Empty/null = unchanged
  /// behaviour (no pinned outbound).
  final String? preferredEdgeIp;

  /// Per-deployment 32-hex random injected into the Worker as PATH_SECRET.
  /// Empty/null means "deployed before the gate landed" — the client emits
  /// the path without ?k= and the Worker template falls through to its old
  /// behaviour. Newly deployed Workers always set this.
  final String? pathSecret;

  /// Sibling hostname pointing at the same Worker. When non-null we emit
  /// a SECOND CDN outbound into the urltest pool so sing-box's auto-failover
  /// gets two paths to the same relay.
  ///
  /// Why this exists: the previous design used a single client-side TLS
  /// probe to decide whether to route via the custom domain or the
  /// `*.workers.dev` fallback. On some networks either hostname can fail in
  /// different ways, and the probe runs from the same network we're trying to
  /// improve. Giving sing-box both hostnames lets urltest's connection-time
  /// test pick whichever path works, no client probe needed.
  ///
  /// Typically [host] is the custom domain and [fallbackHost] is
  /// the `*.workers.dev` URL — but the builder makes no assumption
  /// either way; both go into the urltest pool with equal weight.
  final String? fallbackHost;
}

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
  CdnEndpoint? cdnEndpoint,
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
        // Fall back to the shared deploy default (dl.google.com), NOT
        // www.microsoft.com: microsoft is a multi-CDN geo-balanced target that
        // makes Reality reject the client ("processed invalid connection"), and
        // no deploy path ever bakes it for VLESS. A stale/empty stored
        // server_name previously landed here and produced the exact x509
        // "certificate is valid for *.google.com … not www.microsoft.com"
        // handshake failure seen in the field.
        'server_name': info.vlessServerName.isNotEmpty
            ? info.vlessServerName
            : defaultVlessServerName,
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

  // CDN-fronted variant(s). Routed to a Cloudflare Worker host that
  // relays WS↔TCP to the node's vlessRelayPort. The caller resolves
  // cdnEndpoint to the user's custom domain when bound; if a
  // sibling `fallbackHost` is also supplied (typically the `*.workers.dev`
  // form), we emit a SECOND outbound pointing at it.
  //
  // Why two outbounds: the previous design used a single client-side
  // TLS probe to gate which hostname was wired into the config, and
  // fell back to a single workers.dev outbound on probe failure. On the
  // networks where the custom domain is most useful, the probe runs through
  // the same unhealthy network and may never succeed. Giving sing-box both
  // hostnames lets urltest pick whichever one works, no client-side probe
  // needed.
  //
  // The path always carries the per-deployment PATH_SECRET as ?k=<secret>
  // (when present). The Worker rejects every request that doesn't match
  // with a generic 404, which keeps the relay from being usable as a free
  // out-of-band tunnel by anyone who learns the hostname. Older
  // deployments without a secret emit the same path with `ed=2560`-only;
  // the Worker template falls through for that case.
  final cdnHost = cdnEndpoint?.host;
  if (cdnHost != null &&
      cdnHost.isNotEmpty &&
      info.vlessRelayPort > 0 &&
      info.vlessUuid.isNotEmpty) {
    final secret = cdnEndpoint?.pathSecret;
    // Path-secret goes in a PATH SEGMENT, not a query string. Root cause
    // found 2026-05-28 (codex source-level review): sing-box does NOT
    // parse `?ed=N` query syntax in transport.ws.path — that's an
    // xray/v2ray convention. sing-box uses explicit `max_early_data` +
    // `early_data_header_name` options instead. So sing-box treats the
    // whole `path` string as a literal URL path and Go's
    // url.RequestURI() percent-escapes the `?` to `%3F`. The wire
    // request became `GET /%3Fk=<secret> HTTP/1.1`, so the Worker's
    // `url.searchParams.get('k')` was always null → 404 on every probe.
    // curl/Dart worked because they send a real `?` query. Putting the
    // secret in a path segment (`/<secret>`) survives escaping intact —
    // slashes and hex are not escaped. The Worker now checks the
    // pathname.
    final wsPath = (secret != null && secret.isNotEmpty) ? '/$secret' : '/';

    void addCdnOutbound(String host, String tagSuffix, {String? dialIp}) {
      final tag = '$label-$tagSuffix';
      // 优选IP: when dialIp is given we connect the TCP socket to that IP but
      // keep SNI + WS Host = [host], so Cloudflare still routes to the Worker.
      // No DNS lookup happens for an IP literal, which is the point: it lets
      // advanced users pin a known-good Cloudflare edge address for their
      // current network.
      final dialTarget = (dialIp != null && dialIp.isNotEmpty) ? dialIp : host;
      outbounds.add({
        'type': 'vless',
        'tag': tag,
        'server': dialTarget,
        'server_port': 443,
        'uuid': info.vlessUuid,
        'transport': {
          'type': 'ws',
          'path': wsPath,
          // Browser-like headers on the WS-upgrade. Cloudflare's edge bot
          // heuristics (Bot Fight Mode / Security-Level challenge) score a
          // bare Go WS client dialing from a low-reputation IP (e.g. CN
          // cellular NAT pools) high enough to inject a 403 on the upgrade —
          // even though the Worker itself only returns 404/502/101. Presenting
          // a realistic Chrome User-Agent + Accept-* + Sec-CH-UA set lowers
          // that score. This is defence-in-depth only: the TLS (JA3/JA4)
          // fingerprint is the stronger signal, and the deploy-side CF
          // security relax (see cdn_provider.dart) is the actual root fix.
          'headers': {
            'Host': host,
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept-Encoding': 'gzip, deflate, br, zstd',
            'Origin': 'https://$host',
            'Sec-CH-UA':
                '"Chromium";v="126", "Google Chrome";v="126", "Not.A/Brand";v="24"',
            'Sec-CH-UA-Mobile': '?0',
            'Sec-CH-UA-Platform': '"Windows"',
          },
        },
        'tls': {
          'enabled': true,
          'server_name': host,
          // ALPN must be HTTP/1.1 only. CF Worker WebSocket upgrades use the
          // HTTP/1.1 Upgrade mechanism; over HTTP/2 the runtime strips
          // `Upgrade` + `Connection` headers (they're hop-by-hop), the Worker
          // sees no upgrade, and it returns 404 — silently breaking every WS
          // dial through the Worker even though every other field is correct.
          'alpn': ['http/1.1'],
          // NO uTLS for the CDN outbound. uTLS Chrome's ClientHello carries
          // its own ALPN list (`h2,http/1.1` with h2 preferred) and SILENTLY
          // overrides the `alpn` field above when fingerprint=chrome. CF
          // then picks h2 → Upgrade header gets stripped → Worker returns
          // 404 → urltest deems CDN outbound dead → falls back to bare VPS
          // → direct node reachability fails → user reports "still can't
          // connect" while curl from the same device gets 101 (because
          // curl --http1.1 forces HTTP/1.1).
          //
          // Don't reintroduce uTLS here without first verifying that
          // sing-box's uTLS implementation actually honours the
          // [`alpn`] config when fingerprint is set. The Chrome variant
          // didn't on the build shipped 2026-05-28; the symptom is
          // identical to the original ALPN bug from May 23.
        },
      });
      tags.add(tag);
    }

    addCdnOutbound(cdnHost, 'CDN');
    // Primary tag stays 'CDN' so existing label-based selection (e.g.
    // "preferredEndpointLabel = CDN") continues to point at the
    // user's preferred hostname, not the fallback.
    endpointTagByLabel['CDN'] = '$label-CDN';

    // 优选IP path: an extra urltest member that pins the custom host to a
    // hand-picked fast CF edge IP. Kept ALONGSIDE the DNS-resolved 'CDN'
    // outbound so we don't lose the independent-DNS path if the chosen IP
    // later goes bad — urltest picks whichever wins at connection time.
    final edgeIp = cdnEndpoint?.preferredEdgeIp;
    if (edgeIp != null && edgeIp.isNotEmpty) {
      addCdnOutbound(cdnHost, 'CDN-edgeip', dialIp: edgeIp);
    } else {
      // No user-pinned edge IP: emit a couple of DNS-independent CDN paths that
      // dial a stable Cloudflare anycast edge directly while keeping SNI + WS
      // Host = the custom domain, so CF still routes to the Worker. This is the
      // only CDN path that survives a network which poisons/blocks DNS for the
      // relay's custom domain (observed on CN cellular, which also RSTs
      // `*.workers.dev` by SNI — verified 2026-06-30). The custom domain must be
      // a real bound CF custom hostname for the SNI to route; these IPs are a
      // best-effort fallback and may need refreshing if CF rotates anycast.
      // urltest picks whichever member actually connects.
      for (var i = 0; i < cloudflareEdgeIpFallbacks.length; i++) {
        addCdnOutbound(cdnHost, 'CDN-edge${i + 1}',
            dialIp: cloudflareEdgeIpFallbacks[i]);
      }
    }

    final fallbackHost = cdnEndpoint?.fallbackHost;
    if (fallbackHost != null &&
        fallbackHost.isNotEmpty &&
        fallbackHost != cdnHost) {
      addCdnOutbound(fallbackHost, 'CDN-fallback');
    }
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
  // Cloudflare-fronted host (Workers Custom Domain when M1 is bound,
  // otherwise the *.workers.dev fallback) and using the per-deployment
  // PATH_SECRET on the WS path so the Worker accepts the request. The
  // Worker relays WS frames to the node's vlessRelayPort over plain TCP
  // — see docs/cdn-acceleration. The CDN variant joins the urltest pool
  // so sing-box auto-fails over from direct to CDN when the direct path is
  // unhealthy.
  CdnEndpoint? cdnEndpoint,
  // Other cloud nodes to enroll in the same urltest failover pool. When the
  // active node is unreachable from the current network, sing-box urltest will
  // pick a working failover node automatically. Failover only applies in "auto"
  // mode — if [preferredEndpointLabel] pins a protocol, the user explicitly
  // wants that one outbound and we honor it.
  List<CloudInstance> failoverInstances = const [],
  // Resolves the CDN endpoint for any instance in [failoverInstances].
  // Should return the M1 customHost when bound (with the same
  // pathSecret), and fall back to workerHost when not.
  CdnEndpoint? Function(CloudInstance instance)? failoverCdnEndpointResolver,
}) {
  if (!instance.hasIp || instance.nodeInfo == null) {
    return null;
  }

  // Collect every CDN-front hostname that ends up in the urltest pool so
  // the DNS module can carve them out from the dns-remote loopback. See
  // the rule below the cdnHost-collector for the rationale.
  final cdnHostsForDns = <String>{};
  if (cdnEndpoint?.host != null && cdnEndpoint!.host.isNotEmpty) {
    cdnHostsForDns.add(cdnEndpoint.host);
  }
  if (cdnEndpoint?.fallbackHost != null &&
      cdnEndpoint!.fallbackHost!.isNotEmpty) {
    cdnHostsForDns.add(cdnEndpoint.fallbackHost!);
  }

  final outbounds = <Map<String, dynamic>>[];
  final tags = <String>[];
  final endpointTagByLabel = _appendInstanceOutbounds(
    instance,
    outbounds: outbounds,
    tags: tags,
    cdnEndpoint: cdnEndpoint,
  );
  _prioritizeEdge443ProtocolOrder(instance, outbounds: outbounds, tags: tags);
  // Promote DNS-independent CDN edge paths ahead of bare VPS protocols. On
  // carrier-filtered networks, direct node sockets can burn the urltest timeout
  // budget before a working CDN/Worker path is ever tried.
  _putCdnFirst(outbounds: outbounds, tags: tags);

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
      final fiCdnEndpoint = failoverCdnEndpointResolver?.call(fi);
      if (fiCdnEndpoint?.host != null && fiCdnEndpoint!.host.isNotEmpty) {
        cdnHostsForDns.add(fiCdnEndpoint.host);
      }
      if (fiCdnEndpoint?.fallbackHost != null &&
          fiCdnEndpoint!.fallbackHost!.isNotEmpty) {
        cdnHostsForDns.add(fiCdnEndpoint.fallbackHost!);
      }
      _appendInstanceOutbounds(
        fi,
        outbounds: scratchOutbounds,
        tags: scratchTags,
        cdnEndpoint: fiCdnEndpoint,
      );
      _prioritizeEdge443ProtocolOrder(
        fi,
        outbounds: scratchOutbounds,
        tags: scratchTags,
      );
      _putCdnFirst(
        outbounds: scratchOutbounds,
        tags: scratchTags,
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
  final includeUrlTest = !manualProtocolSelection;

  // Keep the raw DATA members in one urltest, with every CDN member before
  // every direct member. Do not nest `direct-auto` / `cdn-auto` inside `auto`:
  // sing-box starts an outer-group connection through the inner group's
  // initial member before the inner probe has settled. On a carrier that
  // blackholes the bare VPS, that connection remains stuck on direct-auto even
  // after cdn-auto has found a healthy Worker. The Android startup verifier
  // then times out while independent raw CDN probes are visibly succeeding.
  //
  // A flat pool probes all real transports concurrently and can reselect the
  // actual connection. CDN is first so the very first request is usable when
  // the carrier blackholes or heavily throttles the VPS before any probe
  // history exists. Keep a large tolerance so one deceptively fast, tiny
  // direct probe cannot pull real traffic back onto a carrier-throttled port;
  // direct is still selected when every CDN leaf genuinely fails. The two tier
  // groups remain explicit manual choices and diagnostics targets.
  final directDataTags = manualProtocolSelection
      ? <String>[]
      : <String>[
          ...allUrlTestTags
              .where((t) => !t.contains('-CDN') && t.contains('-Hy2')),
          ...allUrlTestTags
              .where((t) => !t.contains('-CDN') && !t.contains('-Hy2')),
        ];
  // Prefer Hysteria2 (UDP/QUIC) at the FRONT of the direct tier. China-Mobile
  // cellular throttles sustained TCP (VLESS/SS/Trojan) to i/o-timeout while
  // Hy2's congestion control punches through — verified on-device: YouTube and
  // Reddit load over Hy2 where TCP-direct timed out (278 i/o-timeouts -> 0).
  // urltest keeps the earliest member unless a later one beats it by more than
  // tolerance, so Hy2-first + a high direct-auto tolerance makes Hy2 the
  // working default and only falls back to TCP when Hy2 (UDP) is actually
  // blocked/unreachable (probe fails). Built with a STABLE Hy2-first partition
  // (NOT List.sort, which is unstable in Dart and would scramble the deliberate
  // non-Hy2 order, e.g. edge443 keeps Trojan 443 ahead of the high-port ones).
  final cdnDataTags = manualProtocolSelection
      ? const <String>[]
      : allUrlTestTags.where((t) => t.contains('-CDN')).toList();
  final hasDirectTier = directDataTags.isNotEmpty;
  final hasCdnTier = cdnDataTags.isNotEmpty;
  // DNS needs the same last-resort reachability as the data plane. Keep the
  // raw protocol members in one dedicated, non-interrupting urltest instead
  // of nesting direct-auto/cdn-auto: both data groups deliberately interrupt
  // existing connections when they reselect, which would tear down in-flight
  // DoH streams. CDN comes first for the same cold-start reason as data; a
  // carrier-blocked direct resolver must not stall every hostname for a full
  // probe timeout before the first page can load.
  final dnsResolverMembers = <String>{
    ...cdnDataTags,
    ...directDataTags,
  }.toList(growable: false);
  final autoDataTags = <String>[
    ...cdnDataTags,
    ...directDataTags,
  ];
  final selectorOutbounds = manualProtocolSelection
      ? List<String>.from(tags.take(1))
      : <String>[
          'auto',
          if (hasDirectTier) 'direct-auto',
          if (hasCdnTier) 'cdn-auto',
          ...allUrlTestTags,
        ];
  // Remote DoH uses a DEDICATED, NON-INTERRUPTING resolver. Direct members are
  // still preferred (Hy2 first), but CDN raw members remain eligible when a
  // carrier blackholes every direct VPS protocol. Without that fallback the
  // data plane can successfully move to cdn-auto while DNS remains pinned to
  // dead direct sockets, producing the misleading "IP literal works, every
  // hostname times out" state. The non-Cloudflare 8.8.8.8 urltest below makes
  // a challenged/broken Worker fail before it can be selected for DoH.
  final dnsResolverDetour = (includeUrlTest && dnsResolverMembers.isNotEmpty)
      ? 'dns-resolver'
      : (includeUrlTest && autoDataTags.isNotEmpty)
          ? 'auto'
          : 'select';

  final config = {
    // Keep per-connection INFO logs available so the diagnostics screen can
    // reconstruct recent DIRECT/PROXY decisions from runtime traffic.
    // Android filters these out of logcat at the service layer to avoid
    // restoring the old log spam problem.
    'log': {'level': _vpnCoreDebugLogs ? 'debug' : 'info'},
    'dns': {
      'servers': [
        {
          'tag': managedDnsRemoteTag,
          // libbox/sing-box v1.11 still uses the legacy DNS server syntax, so
          // we can't set a separate TLS server_name here. Use Cloudflare's
          // IP-literal DoH endpoint to avoid recursively bootstrapping the DNS
          // server hostname through another resolver on Android.
          'address': managedDnsRemoteAddress,
          'detour': dnsResolverDetour,
        },
        {
          'tag': managedDnsRemoteFallbackTag,
          'address': managedDnsRemoteFallbackAddress,
          'detour': dnsResolverDetour,
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
          // api.cloudflare.com belongs here too: when M1 (Workers Custom
          // Domains) is being configured the user is verifying tokens and
          // attaching/detaching Worker domains; if the VPN is already up
          // those calls would tunnel through the proxy node and frequently
          // time out before the user even sees the picker.
          'domain_suffix': [
            'api.vultr.com',
            'api.digitalocean.com',
            'api.cloudflare.com',
          ],
          'server': managedDnsBootstrapTag,
        },
        // CDN-front hosts (custom domain like relay-<hash>.<zone> or the
        // workers.dev fallback) must NOT resolve via dns-remote — that
        // resolver routes through the `select` outbound, whose first
        // member is the CDN outbound itself, which dials this exact host.
        // Without this carve-out sing-box deadlocks with
        // `DNS query loopback in transport[dns-remote]` and urltest
        // never gets a working member. Resolve directly via the
        // bootstrap DNS over the underlying network instead.
        if (cdnHostsForDns.isNotEmpty)
          {
            'domain': cdnHostsForDns.toList(),
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
      // Automatic data path. Raw transports are deliberately flattened so a
      // cold-start connection cannot be trapped in an unresolved nested direct
      // group while a CDN leaf has already passed its end-to-end probe.
      if (includeUrlTest && autoDataTags.isNotEmpty)
        {
          'type': 'urltest',
          'tag': 'auto',
          'interrupt_exist_connections': true,
          'outbounds': autoDataTags,
          'url': 'https://8.8.8.8/generate_204',
          'interval': '1m',
          'tolerance': 1500,
        },
      // Direct tier: best stable direct protocol. Non-Cloudflare IP-literal
      // probe (8.8.8.8/generate_204) so a broken/challenged CDN Worker cannot
      // false-positive by staying inside Cloudflare's edge.
      if (includeUrlTest && hasDirectTier)
        {
          'type': 'urltest',
          'tag': 'direct-auto',
          'interrupt_exist_connections': true,
          'outbounds': directDataTags,
          'url': 'https://8.8.8.8/generate_204',
          'interval': '1m',
          // High tolerance so the Hy2-first ordering wins: a light generate_204
          // probe cannot see the sustained-throughput throttling that kills
          // TCP-direct on cellular, so latency alone must NOT pull selection off
          // Hysteria2. Only a Hy2 probe *failure* (UDP blocked) drops it.
          'tolerance': 3000,
        },
      // Dedicated DNS resolver: direct protocols first, followed by raw CDN
      // protocols as a true last-resort fallback. Keep interruption disabled
      // so periodic urltest probes never tear down an in-flight DoH stream.
      if (includeUrlTest && dnsResolverMembers.isNotEmpty)
        {
          'type': 'urltest',
          'tag': 'dns-resolver',
          'interrupt_exist_connections': false,
          'outbounds': dnsResolverMembers,
          'url': 'https://8.8.8.8/generate_204',
          'interval': '1m',
          'tolerance': 3000,
        },
      // CDN tier: best CDN entry point (CDN-first ordering is kept only *within*
      // this tier). Selected by the outer `auto` only when the direct tier is
      // unavailable — e.g. a carrier that blackholes direct VPS IPs.
      if (includeUrlTest && hasCdnTier)
        {
          'type': 'urltest',
          'tag': 'cdn-auto',
          'interrupt_exist_connections': true,
          'outbounds': cdnDataTags,
          'url': 'https://8.8.8.8/generate_204',
          'interval': '1m',
          'tolerance': 50,
        },
      ...protocolOutbounds,
      {'type': 'direct', 'tag': 'direct'},
      // DNS hijack goes through this dedicated `dns` outbound, NOT the 1.12+
      // `hijack-dns` route-rule action. vpncore bundles sing-box v1.12.12, and
      // on 1.12.12 the `hijack-dns` action silently fails to deliver hijacked
      // queries to the DNS module on the tun (system stack): the router matches
      // `protocol=dns` but app queries never reach a `dns: exchange`, so every
      // in-tunnel hostname resolution dies once Android's pre-VPN DNS cache
      // expires (~4 min after connect) — health probes then false-negative to
      // Unreachable and the session is torn down. Routing DNS to a `dns-out`
      // outbound (deprecated in 1.12, removed only in 1.13, but fully functional
      // here) restores delivery: verified on-device 2026-07-07, fresh queries
      // reach `dns: exchange <host>` and the tunnel stays healthy past the death
      // point. This is what the pre-f2f5204c (WireGuard-era) builds used and why
      // they connected. NOTE: when vpncore is bumped to sing-box 1.13+, `dns-out`
      // disappears and DNS hijack must be re-solved via the action form.
      {'type': 'dns', 'tag': 'dns-out'},
    ],
    'route': {
      'final': 'select',
      'rules': [
        // Route sniffed DNS to the `dns-out` outbound (see outbounds note above);
        // the 1.12+ `{action: hijack-dns}` form is broken on sing-box 1.12.12.
        {'protocol': 'dns', 'outbound': 'dns-out'},
        {
          // sing-box 1.12.0 removed the legacy `geoip` route field; the LAN /
          // private-range direct carve-out is now expressed via `ip_is_private`
          // (available since 1.11). Emitting `geoip: ["private"]` makes the
          // 1.12.x client reject the whole config ("geoip database ... removed
          // in sing-box 1.12.0"), so the VPN never starts — notably on the
          // CDN-front rebuild, which is the only path available on cellular.
          'ip_is_private': true,
          'outbound': 'direct'
        },
        // Cloud-provider management APIs must bypass the tunnel so the user
        // can still validate/refresh API keys while VPN is connected.
        // Otherwise requests egress via the proxy node, whose path to these
        // endpoints is often slow enough to hit the 12s timeout.
        {
          // api.cloudflare.com belongs here too: when M1 (Workers Custom
          // Domains) is being configured the user is verifying tokens and
          // attaching/detaching Worker domains; if the VPN is already up
          // those calls would tunnel through the proxy node and frequently
          // time out before the user even sees the picker.
          'domain_suffix': [
            'api.vultr.com',
            'api.digitalocean.com',
            'api.cloudflare.com',
          ],
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

/// Moves CDN variants ahead of direct node protocols while preserving relative
/// order inside each group. Prefer IP-pinned CDN edges first because they avoid
/// DNS lookup deadlocks on networks that poison or block the relay hostname.
///
/// The urltest probe itself uses HTTPS/443, so CDN paths that only pass TCP or
/// HTTP/80 but fail real HTTPS/WebSocket traffic should be rejected by the
/// probe instead of being selected as false positives.
void _putCdnFirst({
  required List<Map<String, dynamic>> outbounds,
  required List<String> tags,
}) {
  int priority(String tag) {
    if (tag.contains('-CDN-edge')) return 0;
    if (tag.endsWith('-CDN')) return 1;
    if (tag.endsWith('-CDN-fallback')) return 2;
    return 3;
  }

  if (!tags.any((tag) => priority(tag) < 3)) {
    return;
  }

  final orderedTags = tags.asMap().entries.toList()
    ..sort((a, b) {
      final byPriority = priority(a.value).compareTo(priority(b.value));
      if (byPriority != 0) return byPriority;
      return a.key.compareTo(b.key);
    });

  final outboundByTag = <String, Map<String, dynamic>>{
    for (final outbound in outbounds)
      if (outbound['tag'] is String) outbound['tag'] as String: outbound,
  };
  final reorderedTags = orderedTags.map((entry) => entry.value).toList();
  final reorderedOutbounds = <Map<String, dynamic>>[
    for (final tag in reorderedTags)
      if (outboundByTag[tag] != null) outboundByTag[tag]!,
  ];

  tags
    ..clear()
    ..addAll(reorderedTags);
  outbounds
    ..clear()
    ..addAll(reorderedOutbounds);
}

void _prioritizeEdge443ProtocolOrder(
  CloudInstance instance, {
  required List<Map<String, dynamic>> outbounds,
  required List<String> tags,
}) {
  final info = instance.nodeInfo;
  if (info == null || info.trojanPort != 443) {
    return;
  }

  int priority(String tag) {
    if (tag.endsWith('-Trojan')) return 0;
    if (tag.endsWith('-Hy2')) return 1;
    if (tag.endsWith('-VLESS')) return 2;
    if (tag.endsWith('-SS')) return 3;
    if (tag.endsWith('-CDN')) return 4; // custom-domain DNS
    if (tag.endsWith('-CDN-fallback')) return 5; // workers.dev DNS
    if (tag.contains('-CDN-edge')) return 6; // IP-pinned edge
    return 7;
  }

  tags.sort((a, b) {
    final byPriority = priority(a).compareTo(priority(b));
    return byPriority != 0 ? byPriority : a.compareTo(b);
  });

  outbounds.sort((a, b) {
    final aTag = a['tag']?.toString() ?? '';
    final bTag = b['tag']?.toString() ?? '';
    final byPriority = priority(aTag).compareTo(priority(bTag));
    return byPriority != 0 ? byPriority : aTag.compareTo(bTag);
  });
}
