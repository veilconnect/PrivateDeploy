import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/network/managed_dns_defaults.dart';
import '../settings/app_settings_provider.dart';
import 'bundled_rule_set_registry.dart';

const _managedGeositeCnTag = 'pd-geosite-cn';
const _managedGeoipCnTag = 'pd-geoip-cn';
const _androidTunDnsTlsPort = 853;
const _androidPrivateDnsProbeLoopbackCidrs = ['127.0.0.0/8', '::1/128'];
const _dnsRemoteTag = managedDnsRemoteTag;
const _dnsRemoteFallbackTag = managedDnsRemoteFallbackTag;
const _dnsBootstrapTag = managedDnsBootstrapTag;
const _dnsLocalTag = managedDnsLocalTag;
const _dnsCnTag = managedDnsCnTag;
const _dnsRemoteAddress = managedDnsRemoteAddress;
const _dnsRemoteFallbackAddress = managedDnsRemoteFallbackAddress;
const _dnsBootstrapAddress = managedDnsBootstrapAddress;
const _dnsCnAddress = managedDnsCnAddress;
// Cloud-management APIs that must bypass the tunnel even when the user is
// running a non-cloud profile (subscription, manual config). api.cloudflare.com
// belongs here too: M1 (Workers Custom Domains) configures itself by hitting
// CF; if the VPN is up and CF tunnels through the proxy node, those calls
// often time out before the user even sees the picker.
const _cloudProviderApiDomains = [
  'api.vultr.com',
  'api.digitalocean.com',
  'api.cloudflare.com',
];

// Legacy core: pre-M1 configs only listed Vultr+DO. The "is this our
// managed cloud-API bypass rule?" heuristic still accepts those so old
// persisted profiles keep being recognized after we expanded the domain
// list above.
const _cloudProviderApiCoreDomains = [
  'api.vultr.com',
  'api.digitalocean.com',
];

String normalizeProfileConfigForCurrentPlatform(
  String content, {
  TargetPlatform? targetPlatform,
  VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
  BundledRuleSetPaths bundledRuleSetPaths = const BundledRuleSetPaths(),
}) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      return content;
    }

    final isAndroid =
        (targetPlatform ?? defaultTargetPlatform) == TargetPlatform.android;
    var changed = false;
    if (isAndroid) {
      changed = _normalizeAndroidConfig(decoded) || changed;
    }
    changed = _applyRoutingSettings(
          decoded,
          routingSettings,
          bundledRuleSetPaths,
          isAndroid: isAndroid,
        ) ||
        changed;
    // Collapse any true-duplicate WireGuard endpoints (same key + server + port)
    // down to one survivor, retargeting references. Runs independently of the
    // overlay so it also covers the overlay-OFF case (a full-tunnel WG node plus
    // a same-key custom outbound), where two live endpoints would steal the
    // single per-pubkey session from each other and the tunnel keeps dropping.
    changed = _collapseDuplicateWireguardPeers(decoded) || changed;
    // Overlay the independent intranet WireGuard tunnel last, so its LAN rule
    // sits above the proxy/direct routing produced above.
    changed = _applyWireGuardIntranet(
          decoded,
          routingSettings.wireGuardIntranet,
        ) ||
        changed;
    // Whenever the config carries ANY WireGuard endpoint — including legacy
    // full-tunnel profiles saved before tun MTU was baked in, and the overlay
    // early-return paths above — clamp the TUN MTU to fit the WG path. A TUN
    // left at sing-box's 9000 default lets large packets enter and stall
    // against the (typically 1408) WireGuard MTU, which reads as random drops.
    changed = _clampTunMtuForWireguard(decoded) || changed;

    if (!changed) {
      return content;
    }
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return content;
  }
}

bool _normalizeAndroidConfig(Map<String, dynamic> decoded) {
  var changed = false;
  final shouldForceGvisorForProxyImport =
      _looksLikeAndroidProxyImportConfig(decoded);
  final shouldForceSystemForCloudProfile =
      _looksLikeAndroidCloudProfileConfig(decoded);

  final route = _ensureMap(decoded, 'route');
  if (route.containsKey('override_android_vpn')) {
    route.remove('override_android_vpn');
    changed = true;
  }
  if (shouldForceSystemForCloudProfile &&
      route['default_network_strategy']?.toString().trim() != 'default') {
    // Older Android cloud profiles relied on protect(fd) alone. That keeps
    // Wi-Fi sessions working, but after the device leaves Wi-Fi, upstream
    // sockets can stay on the stale path and fail over cellular. For cloud
    // profiles, always follow Android's current default underlying network.
    route['default_network_strategy'] = 'default';
    changed = true;
  }

  if (shouldForceGvisorForProxyImport) {
    final log = _ensureMap(decoded, 'log');
    if (log['level']?.toString().trim().toLowerCase() != 'info') {
      log['level'] = 'info';
      changed = true;
    }
    final selector = _findTaggedOutbound(decoded, tag: 'select');
    final selectorOutbounds = selector?['outbounds'];
    if (selectorOutbounds is List &&
        selectorOutbounds.any((value) => value?.toString() == 'auto') &&
        selector?['default']?.toString().trim() != 'auto') {
      selector?['default'] = 'auto';
      changed = true;
    }
  }

  final inbounds = decoded['inbounds'];
  // Inject a default tun inbound when the profile has none. Without it,
  // libbox starts cleanly but Android never sees an OpenTun call, so the
  // VpnService never establishes a tunnel — the app shows "已连接" while
  // traffic continues to bypass sing-box entirely (egress probe returns the
  // device's underlying public IP and the byte counters stay at 0). This
  // mostly affected raw-JSON profiles that ship just `outbounds`; subscription
  // and cloud profiles already get a tun inbound from their builders.
  if (inbounds is! List || inbounds.isEmpty) {
    final outboundsForTun = decoded['outbounds'];
    if (outboundsForTun is List && outboundsForTun.isNotEmpty) {
      decoded['inbounds'] = <Map<String, dynamic>>[
        // strict_route is intentionally omitted: subscription/cloud profiles
        // pair it with full DNS + route rules so the egress probe is steered
        // to the right outbound. Bare profiles (raw `direct` outbound only)
        // don't have those rules, and strict_route turns the probe socket
        // into a routing dead-end during startup verification.
        <String, dynamic>{
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'tun0',
          'inet4_address': '172.19.0.1/30',
          'auto_route': true,
          'stack': 'gvisor',
          'sniff': true,
        },
      ];
      // The tun inbound captures DNS, so without an explicit DNS config the
      // resolver loops back into the tunnel with no upstream — every
      // hostname lookup hangs (verified: `ping api.ipify.org` returned
      // "unknown host" while the tunnel was up). Inject a minimal local
      // DNS pointing at the device's underlying resolver via the existing
      // outbound, but only if the user hasn't supplied one already.
      if (decoded['dns'] is! Map) {
        final firstOutboundTag = outboundsForTun
            .whereType<Map<String, dynamic>>()
            .map((o) => o['tag']?.toString())
            .firstWhere((t) => t != null && t.isNotEmpty, orElse: () => null);
        decoded['dns'] = <String, dynamic>{
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'dns-local',
              'address': 'local',
              if (firstOutboundTag != null) 'detour': firstOutboundTag,
            },
          ],
          'strategy': 'prefer_ipv4',
        };
        changed = true;
      }
    }
  }

  final inboundsForStack = decoded['inbounds'];
  if (inboundsForStack is List) {
    for (final inbound in inboundsForStack) {
      if (inbound is! Map<String, dynamic>) {
        continue;
      }
      if (inbound['type']?.toString() != 'tun') {
        continue;
      }

      final stack = inbound['stack']?.toString().trim();
      if (shouldForceSystemForCloudProfile && stack == 'gvisor') {
        // Older Android cloud profiles were generated with gVisor. That keeps
        // some Wi-Fi-only sessions alive, but it breaks more important cases
        // when the device leaves Wi-Fi and has to keep the VPN running over
        // mobile data using Android's native 464XLAT/NAT64 path.
        inbound['stack'] = 'system';
        changed = true;
        continue;
      }
      if (shouldForceGvisorForProxyImport && stack == 'system') {
        // Older proxy-link imports were generated with the system stack.
        // On some Samsung devices that leaves the VPN connected while
        // proxied DNS loops back into dns-remote and all browsing stalls.
        inbound['stack'] = 'gvisor';
        changed = true;
        continue;
      }
      // Preserve an explicit `system` stack. Android mobile networks may rely
      // on platform features such as 464XLAT/NAT64 to reach IPv4-only proxy
      // nodes, and overriding that choice to gVisor can break cellular-only
      // connectivity on some devices/carriers.
      if (stack == null || stack.isEmpty) {
        inbound['stack'] = 'gvisor';
        changed = true;
      }
    }
  }

  final unsupportedTags = <String>{};
  final outbounds = decoded['outbounds'];
  if (outbounds is List) {
    outbounds.removeWhere((outbound) {
      if (outbound is! Map<String, dynamic>) {
        return false;
      }
      if (!isUnsupportedAndroidOutbound(outbound)) {
        return false;
      }
      final tag = outbound['tag']?.toString();
      if (tag != null && tag.isNotEmpty) {
        unsupportedTags.add(tag);
      }
      changed = true;
      return true;
    });

    while (unsupportedTags.isNotEmpty) {
      var passChanged = false;
      outbounds.removeWhere((outbound) {
        if (outbound is! Map<String, dynamic>) {
          return false;
        }
        final refs = outbound['outbounds'];
        if (refs is! List) {
          return false;
        }

        final before = refs.length;
        refs.removeWhere(
          (value) => unsupportedTags.contains(value?.toString()),
        );
        if (refs.length != before) {
          changed = true;
          passChanged = true;
        }

        final defaultTag = outbound['default']?.toString();
        if (refs.isNotEmpty &&
            defaultTag != null &&
            defaultTag.isNotEmpty &&
            !refs.any((value) => value?.toString() == defaultTag)) {
          outbound['default'] = refs.first.toString();
          changed = true;
          passChanged = true;
        }

        if (refs.isNotEmpty) {
          return false;
        }

        final tag = outbound['tag']?.toString();
        if (tag != null && tag.isNotEmpty) {
          unsupportedTags.add(tag);
        }
        changed = true;
        passChanged = true;
        return true;
      });

      if (!passChanged) {
        break;
      }
    }
  }

  final selector = _findTaggedOutbound(decoded, tag: 'select');
  final selectorOutbounds = selector?['outbounds'];
  if (selectorOutbounds is List &&
      selectorOutbounds.any((value) => value?.toString() == 'auto') &&
      selector?['interrupt_exist_connections'] != true) {
    selector?['interrupt_exist_connections'] = true;
    changed = true;
  }

  final autoGroup = _findTaggedOutbound(decoded, tag: 'auto');
  if (autoGroup != null && autoGroup['type']?.toString() == 'urltest') {
    if (autoGroup['interrupt_exist_connections'] != true) {
      autoGroup['interrupt_exist_connections'] = true;
      changed = true;
    }
    if (autoGroup.containsKey('idle_timeout')) {
      autoGroup.remove('idle_timeout');
      changed = true;
    }
  }

  return changed;
}

bool _looksLikeAndroidCloudProfileConfig(Map<String, dynamic> decoded) {
  final dns = decoded['dns'];
  final route = decoded['route'];
  final outbounds = decoded['outbounds'];
  if (dns is! Map<String, dynamic> ||
      route is! Map<String, dynamic> ||
      outbounds is! List<dynamic>) {
    return false;
  }

  final dnsRules = _coerceMapList(dns['rules']);
  final routeRules = _coerceMapList(route['rules']);
  final hasCloudDnsBypass = dnsRules.any(
    (rule) =>
        rule['server']?.toString() == _dnsBootstrapTag &&
        _isCloudProviderApiDnsBypassRule(rule),
  );
  final hasCloudRouteBypass = routeRules.any(
    (rule) =>
        rule['outbound']?.toString() == 'direct' &&
        _isCloudProviderApiBypassRule(rule),
  );
  if (!hasCloudDnsBypass || !hasCloudRouteBypass) {
    return false;
  }

  final selector = outbounds
      .whereType<Map>()
      .cast<Map<String, dynamic>>()
      .where(
        (outbound) =>
            outbound['type']?.toString() == 'selector' &&
            outbound['tag']?.toString() == 'select',
      )
      .cast<Map<String, dynamic>>()
      .firstWhere(
        (_) => true,
        orElse: () => const <String, dynamic>{},
      );
  final selectorOutbounds = selector['outbounds'];
  if (selectorOutbounds is! List<dynamic>) {
    return false;
  }
  return selectorOutbounds.any((value) {
    final tag = value?.toString() ?? '';
    return tag.endsWith('-SS') ||
        tag.endsWith('-Hy2') ||
        tag.endsWith('-VLESS') ||
        tag.endsWith('-Trojan');
  });
}

bool _looksLikeAndroidProxyImportConfig(Map<String, dynamic> decoded) {
  final dns = decoded['dns'];
  final outbounds = decoded['outbounds'];
  final route = decoded['route'];
  if (dns is! Map<String, dynamic> ||
      outbounds is! List<dynamic> ||
      route is! Map<String, dynamic>) {
    return false;
  }

  final dnsServers = dns['servers'];
  if (dnsServers is! List<dynamic>) {
    return false;
  }

  Map<String, dynamic>? dnsRemote;
  final dnsTags = <String>{};
  for (final server in dnsServers) {
    if (server is! Map<String, dynamic>) {
      continue;
    }
    final tag = server['tag']?.toString();
    if (tag == null || tag.isEmpty) {
      continue;
    }
    dnsTags.add(tag);
    if (tag == 'dns-remote') {
      dnsRemote = server;
    }
  }

  if (!dnsTags.containsAll({'dns-remote', 'dns-direct', 'dns-local'})) {
    return false;
  }
  if (dnsRemote == null ||
      dnsRemote['address']?.toString() != 'https://1.1.1.1/dns-query' ||
      dnsRemote['detour']?.toString() != 'select') {
    return false;
  }

  Map<String, dynamic>? selector;
  Map<String, dynamic>? urltest;
  final outboundTags = <String>{};
  for (final outbound in outbounds) {
    if (outbound is! Map<String, dynamic>) {
      continue;
    }
    final tag = outbound['tag']?.toString();
    if (tag != null && tag.isNotEmpty) {
      outboundTags.add(tag);
    }
    if (outbound['type']?.toString() == 'selector' &&
        outbound['tag']?.toString() == 'select') {
      selector = outbound;
    }
    if (outbound['type']?.toString() == 'urltest' &&
        outbound['tag']?.toString() == 'auto') {
      urltest = outbound;
    }
  }

  if (selector == null ||
      urltest == null ||
      !outboundTags.containsAll({'direct', 'dns-out', 'block'})) {
    return false;
  }

  final selectorOutbounds = selector['outbounds'];
  if (selectorOutbounds is! List<dynamic> ||
      !selectorOutbounds.any((value) => value?.toString() == 'auto')) {
    return false;
  }

  if (route['auto_detect_interface'] != true) {
    return false;
  }

  final routeRules = route['rules'];
  if (routeRules is! List<dynamic>) {
    return false;
  }
  return routeRules.any(
    (rule) =>
        rule is Map<String, dynamic> &&
        rule['protocol']?.toString() == 'dns' &&
        rule['outbound']?.toString() == 'dns-out',
  );
}

Map<String, dynamic>? _findTaggedOutbound(
  Map<String, dynamic> decoded, {
  required String tag,
}) {
  final outbounds = decoded['outbounds'];
  if (outbounds is! List<dynamic>) {
    return null;
  }
  for (final outbound in outbounds) {
    if (outbound is Map<String, dynamic> &&
        outbound['tag']?.toString() == tag) {
      return outbound;
    }
  }
  return null;
}

bool _ensureProxyServerDomainsResolveDirect(Map<String, dynamic> decoded) {
  final outbounds = decoded['outbounds'];
  final dns = decoded['dns'];
  final route = decoded['route'];
  if (outbounds is! List<dynamic> ||
      dns is! Map<String, dynamic> ||
      route is! Map<String, dynamic>) {
    return false;
  }

  final proxyServerDomains = <String>{};
  for (final outbound in outbounds) {
    if (outbound is! Map<String, dynamic>) {
      continue;
    }
    final server = outbound['server']?.toString().trim();
    if (server == null ||
        server.isEmpty ||
        server == 'localhost' ||
        InternetAddress.tryParse(server) != null) {
      continue;
    }
    proxyServerDomains.add(server);
  }

  if (proxyServerDomains.isEmpty) {
    return false;
  }

  final dnsServers = dns['servers'];
  if (dnsServers is! List<dynamic> ||
      !dnsServers.any(
        (server) =>
            server is Map<String, dynamic> &&
            server['tag']?.toString() == 'dns-direct',
      )) {
    return false;
  }

  var changed = false;

  final dnsRules = _ensureList<Map<String, dynamic>>(dns, 'rules');
  final directDnsRuleIndex = dnsRules.indexWhere(
    (rule) =>
        _sameStringSet(rule['domain'], proxyServerDomains) &&
        rule['server']?.toString() == 'dns-direct',
  );
  if (directDnsRuleIndex == -1) {
    dnsRules.insert(
      _firstCatchAllDnsRuleIndex(dnsRules),
      {
        'domain': proxyServerDomains.toList()..sort(),
        'server': 'dns-direct',
      },
    );
    changed = true;
  }

  final routeRules = _ensureList<Map<String, dynamic>>(route, 'rules');
  final directRouteRuleIndex = routeRules.indexWhere(
    (rule) =>
        _sameStringSet(rule['domain'], proxyServerDomains) &&
        rule['outbound']?.toString() == 'direct',
  );
  if (directRouteRuleIndex == -1) {
    routeRules.insert(
      _firstDnsProtocolRouteRuleIndex(routeRules) + 1,
      {
        'domain': proxyServerDomains.toList()..sort(),
        'outbound': 'direct',
      },
    );
    changed = true;
  }

  return changed;
}

int _firstCatchAllDnsRuleIndex(List<Map<String, dynamic>> rules) {
  final index = rules.indexWhere(
    (rule) => (rule['outbound'] as List<dynamic>?)?.contains('any') == true,
  );
  return index == -1 ? rules.length : index;
}

int _firstDnsProtocolRouteRuleIndex(List<Map<String, dynamic>> rules) {
  return rules.indexWhere(
    (rule) =>
        rule['protocol']?.toString() == 'dns' &&
        rule['outbound']?.toString() == 'dns-out',
  );
}

bool _sameStringSet(dynamic value, Set<String> expected) {
  if (value is! List<dynamic>) {
    return false;
  }
  final actual =
      value.map((item) => item?.toString()).whereType<String>().toSet();
  return actual.length == expected.length && actual.containsAll(expected);
}

bool _applyRoutingSettings(Map<String, dynamic> decoded,
    VpnRoutingSettings routingSettings, BundledRuleSetPaths bundledRuleSetPaths,
    {required bool isAndroid}) {
  final originalJson = jsonEncode(decoded);
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) {
    return false;
  }
  final tunSubnetCidrs =
      isAndroid ? _extractTunSubnetCidrs(decoded) : const <String>[];
  final privateDnsProbeCidrs = isAndroid
      ? _dedupeStrings([
          ..._androidPrivateDnsProbeLoopbackCidrs,
          ...tunSubnetCidrs,
        ])
      : const <String>[];
  if (privateDnsProbeCidrs.isNotEmpty) {
    _ensureBlockOutbound(outbounds);
  }

  final outboundMaps = outbounds.whereType<Map>().map<Map<String, dynamic>>(
        (outbound) => Map<String, dynamic>.from(outbound),
      );
  final outboundTags = outboundMaps
      .map((outbound) => outbound['tag']?.toString().trim())
      .whereType<String>()
      .where((tag) => tag.isNotEmpty)
      .toSet();
  final proxyServerDomains = _extractProxyServerDomains(
    outboundMaps.toList(growable: false),
  );

  // Endpoints (e.g. WireGuard on sing-box 1.12) share the outbound tag
  // namespace. Fold any already-present endpoint tags into the known-tag set so
  // custom rules can target them and re-normalizing an already-converted config
  // stays idempotent (the conversion below won't append a duplicate endpoint).
  final existingEndpoints = decoded['endpoints'];
  if (existingEndpoints is List) {
    for (final endpoint in existingEndpoints.whereType<Map>()) {
      final tag = endpoint['tag']?.toString().trim();
      if (tag != null && tag.isNotEmpty) {
        outboundTags.add(tag);
      }
    }
  }

  // Merge user-defined custom outbounds (e.g. a WireGuard tunnel to a private
  // network) so custom routing rules can target them. Skip any whose tag
  // already exists to avoid clobbering node/proxy/structural outbounds.
  for (final customOutbound in routingSettings.customOutbounds) {
    final tag = customOutbound['tag']?.toString().trim();
    final type = customOutbound['type']?.toString().trim();
    if (tag == null || tag.isEmpty || type == null || type.isEmpty) {
      continue;
    }
    if (outboundTags.contains(tag)) {
      continue;
    }
    if (type == 'wireguard') {
      // sing-box 1.12 dropped the legacy WireGuard *outbound* (it requires
      // ENABLE_DEPRECATED_WIREGUARD_OUTBOUND and rejects the whole config on
      // `persistent_keepalive_interval`). WireGuard now lives under top-level
      // `endpoints` with the peer fields nested. The user still pastes the
      // familiar outbound-shaped JSON; convert it here, mirroring the desktop
      // generateEndpoints field mapping, and keep keepalive inside the peer.
      final endpoints = _ensureList<Map<String, dynamic>>(decoded, 'endpoints');
      endpoints.add(_buildWireguardEndpoint(customOutbound));
      outboundTags.add(tag);
      continue;
    }
    outbounds.add(Map<String, dynamic>.from(customOutbound));
    outboundTags.add(tag);
  }

  final hasDirectOutbound = outboundTags.contains('direct');
  final hasDnsOutbound = outboundTags.contains('dns-out');
  final route = _ensureMap(decoded, 'route');
  final proxyOutboundTag = _selectProxyOutboundTag(
    routeFinal: route['final']?.toString(),
    outbounds: outboundMaps.toList(growable: false),
    outboundTags: outboundTags,
  );
  _ensureManagedDnsServers(
    decoded,
    routingSettings: routingSettings,
    hasDirectOutbound: hasDirectOutbound,
    proxyOutboundTag: proxyOutboundTag,
  );
  _ensureManagedDnsDefaults(decoded);
  _ensureProxyServerDomainsResolveDirect(decoded);

  final existingRules = _coerceMapList(route['rules']);
  final preservedRules = existingRules
      .where((rule) => !_isManagedOrLegacyRule(rule))
      .toList(growable: false);
  final managedRules = <Map<String, dynamic>>[];

  if (privateDnsProbeCidrs.isNotEmpty &&
      outboundTags.contains('block') &&
      !_containsAndroidPrivateDnsCompatRule(
          existingRules, privateDnsProbeCidrs)) {
    managedRules.add({
      'network': 'tcp',
      'port': _androidTunDnsTlsPort,
      'ip_cidr': privateDnsProbeCidrs,
      'outbound': 'block',
    });
  }

  if (hasDnsOutbound) {
    managedRules.add({
      'protocol': 'dns',
      'outbound': 'dns-out',
    });
  }

  // User-defined custom rules take priority over the built-in private/CN
  // rules below, so e.g. `10.0.0.0/24 -> home-wg` wins over `ip_is_private ->
  // direct`. Only emit rules whose target outbound actually exists (built-in
  // direct/proxy or a merged custom outbound) to keep the config valid.
  for (final rule in routingSettings.customRules) {
    final value = rule.value.trim();
    final outbound = rule.outbound.trim();
    if (value.isEmpty || outbound.isEmpty || !outboundTags.contains(outbound)) {
      continue;
    }
    switch (rule.matcher) {
      case CustomRuleMatcher.domainSuffix:
        _appendDomainSuffixRule(managedRules, [value], outbound);
        break;
      case CustomRuleMatcher.ipCidr:
        _appendIpCidrRule(managedRules, [value], outbound);
        break;
    }
  }

  if (isAndroid && proxyOutboundTag != null) {
    _appendPackageRule(
      managedRules,
      routingSettings.customProxyPackages,
      proxyOutboundTag,
    );
  }

  if (isAndroid && hasDirectOutbound) {
    _appendPackageRule(
      managedRules,
      effectiveAndroidDirectPackages(routingSettings),
      'direct',
    );
  }

  if (hasDirectOutbound && routingSettings.directPrivateNetworks) {
    managedRules.add({
      'ip_is_private': true,
      'outbound': 'direct',
    });
  }

  // Always bypass the tunnel for cloud-provider management APIs so API key
  // validation/refresh works while VPN is connected. Without this, requests
  // egress via the proxy node whose path to these endpoints often exceeds
  // the 12s client timeout.
  if (hasDirectOutbound) {
    managedRules.add({
      'domain_suffix': _cloudProviderApiDomains,
      'outbound': 'direct',
    });
  }

  if (proxyOutboundTag != null) {
    _appendDomainSuffixRule(
      managedRules,
      routingSettings.customProxyDomains,
      proxyOutboundTag,
    );
    _appendIpCidrRule(
      managedRules,
      routingSettings.customProxyCidrs,
      proxyOutboundTag,
    );
  }

  if (hasDirectOutbound) {
    _appendDomainSuffixRule(
      managedRules,
      routingSettings.customDirectDomains,
      'direct',
    );
    _appendIpCidrRule(
      managedRules,
      routingSettings.customDirectCidrs,
      'direct',
    );
  }

  final managedRuleSets = <Map<String, dynamic>>[];
  if (hasDirectOutbound && routingSettings.isSplitMode) {
    if (routingSettings.directCnDomains) {
      final geositeCnPath = bundledRuleSetPaths.geositeCnPath;
      if (geositeCnPath != null && geositeCnPath.isNotEmpty) {
        managedRules.add({
          'rule_set': _managedGeositeCnTag,
          'outbound': 'direct',
        });
        managedRuleSets.add(
          _buildBundledRuleSet(
            tag: _managedGeositeCnTag,
            path: geositeCnPath,
          ),
        );
      }
    }
    if (routingSettings.directCnIpRanges) {
      final geoipCnPath = bundledRuleSetPaths.geoipCnPath;
      if (geoipCnPath != null && geoipCnPath.isNotEmpty) {
        managedRules.add({
          'rule_set': _managedGeoipCnTag,
          'outbound': 'direct',
        });
        managedRuleSets.add(
          _buildBundledRuleSet(
            tag: _managedGeoipCnTag,
            path: geoipCnPath,
          ),
        );
      }
    }
  }

  route['rules'] = [
    ...managedRules,
    ...preservedRules,
  ];

  final preservedRuleSets = _coerceMapList(route['rule_set'])
      .where((ruleSet) => !_isManagedRuleSet(ruleSet))
      .toList(growable: false);
  if (managedRuleSets.isEmpty && preservedRuleSets.isEmpty) {
    route.remove('rule_set');
  } else {
    route['rule_set'] = [
      ...preservedRuleSets,
      ...managedRuleSets,
    ];
  }

  if (proxyOutboundTag != null) {
    route['final'] = proxyOutboundTag;
  }

  if (managedRuleSets.isNotEmpty) {
    final experimental = _ensureMap(decoded, 'experimental');
    final cacheFile = _ensureMap(experimental, 'cache_file');
    cacheFile['enabled'] = true;
  }

  final dns = _ensureMap(decoded, 'dns');
  final existingDnsRules = _coerceMapList(dns['rules']);
  final preservedDnsRules = existingDnsRules
      .where((rule) => !_isManagedDnsRule(rule))
      .toList(growable: false);
  final managedDnsRules = <Map<String, dynamic>>[];
  if (hasDirectOutbound) {
    managedDnsRules.add({
      'domain_suffix': _cloudProviderApiDomains,
      'server': _dnsBootstrapTag,
    });
  }
  if (hasDirectOutbound) {
    _appendDnsDomainRule(
      managedDnsRules,
      proxyServerDomains.toList()..sort(),
      _dnsBootstrapTag,
    );
  }
  if (hasDirectOutbound &&
      routingSettings.dnsMode == VpnDnsMode.regionalOptimized) {
    final directDnsServerTag = _resolveDirectDnsServerTag(routingSettings);
    _appendDnsDomainSuffixRule(
      managedDnsRules,
      routingSettings.customDirectDomains,
      directDnsServerTag,
    );
    if (routingSettings.isSplitMode && routingSettings.directCnDomains) {
      final geositeCnPath = bundledRuleSetPaths.geositeCnPath;
      if (geositeCnPath != null && geositeCnPath.isNotEmpty) {
        managedDnsRules.add({
          'rule_set': _managedGeositeCnTag,
          'server': directDnsServerTag,
        });
      }
    }
  }
  if (proxyOutboundTag != null &&
      routingSettings.dnsMode != VpnDnsMode.systemResolver) {
    _appendDnsDomainSuffixRule(
      managedDnsRules,
      managedDnsRemoteFallbackDomainSuffixes,
      _dnsRemoteFallbackTag,
    );
  }
  managedDnsRules.add({
    'outbound': ['any'],
    'server': _resolveDefaultDnsServerTag(
      routingSettings,
      hasDirectOutbound: hasDirectOutbound,
      proxyOutboundTag: proxyOutboundTag,
    ),
  });
  dns['rules'] = [
    ...managedDnsRules,
    ...preservedDnsRules,
  ];

  // On Android, apply per-app package filtering at the TUN inbound level.
  // This uses VpnService.Builder.addDisallowedApplication() so that direct
  // apps' traffic never enters the TUN interface at all — a reliable bypass
  // regardless of the sing-box network stack in use.
  if (isAndroid) {
    _applyTunPackageFiltering(decoded, routingSettings);
  }

  return originalJson != jsonEncode(decoded);
}

void _applyTunPackageFiltering(
  Map<String, dynamic> decoded,
  VpnRoutingSettings routingSettings,
) {
  final inbounds = decoded['inbounds'];
  if (inbounds is! List) {
    return;
  }

  final directPackages = _dedupeStrings(
    effectiveAndroidDirectPackages(routingSettings),
  );

  for (final inbound in inbounds) {
    if (inbound is! Map<String, dynamic>) {
      continue;
    }
    if (inbound['type']?.toString() != 'tun') {
      continue;
    }

    if (directPackages.isNotEmpty) {
      // Exclude direct packages from TUN so their traffic bypasses VPN
      // entirely via Android VpnService.Builder.addDisallowedApplication().
      final existing = _coerceStringList(inbound['exclude_package']);
      final merged = _dedupeStrings([...existing, ...directPackages]);
      inbound['exclude_package'] = merged;
    }
  }
}

/// Converts a user-supplied legacy WireGuard *outbound* JSON map into a
/// sing-box 1.12 WireGuard *endpoint* map. Field mapping mirrors the desktop
/// `generateEndpoints` (frontend/src/utils/generator.ts):
///   local_address -> address, private_key/mtu stay at the endpoint level;
///   server -> peers[].address, server_port -> peers[].port,
///   peer_public_key -> peers[].public_key, pre_shared_key/keepalive nested in
///   the peer. `allowed_ips` defaults to a full route so the route layer alone
///   decides what traffic reaches the tunnel.
Map<String, dynamic> _buildWireguardEndpoint(Map<String, dynamic> outbound) {
  final peer = <String, dynamic>{
    'address': outbound['server'],
  };
  final port = _asIntOrNull(outbound['server_port']);
  if (port != null) {
    peer['port'] = port;
  }
  peer['public_key'] = outbound['peer_public_key'];
  final preSharedKey = outbound['pre_shared_key']?.toString().trim();
  if (preSharedKey != null && preSharedKey.isNotEmpty) {
    peer['pre_shared_key'] = outbound['pre_shared_key'];
  }
  // Honor an explicit allowed_ips (e.g. the intranet overlay scopes the tunnel
  // to LAN ranges only); otherwise default to a full route and let the route
  // layer decide what reaches the tunnel.
  final explicitAllowed = _coerceStringList(outbound['allowed_ips']);
  peer['allowed_ips'] = explicitAllowed.isNotEmpty
      ? explicitAllowed
      : const ['0.0.0.0/0', '::/0'];
  // Keepalive: a WireGuard peer behind NAT whose mapping isn't refreshed goes
  // silent after a minute or two of idle — the classic "WireGuard keeps
  // disconnecting". So default to 25s (the wg-quick default) when the source
  // OMITS the field (the custom-outbound builder and pasted routing-rules JSON
  // both omit it, so without a default those tunnels drop on idle). Only an
  // EXPLICIT non-positive value counts as an opt-out — callers that want no
  // keepalive must pass `persistent_keepalive_interval: 0`, not drop the key.
  if (outbound.containsKey('persistent_keepalive_interval')) {
    final keepalive = _asIntOrNull(outbound['persistent_keepalive_interval']);
    if (keepalive != null && keepalive > 0) {
      peer['persistent_keepalive_interval'] = keepalive;
    }
    // present and <= 0 (explicit opt-out), or unparseable: emit no keepalive.
  } else {
    peer['persistent_keepalive_interval'] = 25;
  }

  final endpoint = <String, dynamic>{
    'type': 'wireguard',
    'tag': outbound['tag']?.toString().trim(),
    'address': _coerceStringList(outbound['local_address']),
    'private_key': outbound['private_key'],
    'peers': [peer],
  };
  final mtu = _asIntOrNull(outbound['mtu']);
  if (mtu != null && mtu > 0) {
    endpoint['mtu'] = mtu;
  }
  return endpoint;
}

/// Builds a complete, connectable full-tunnel sing-box config from WireGuard
/// form fields, so a WireGuard server can be added and connected to like any
/// other VPN node (it shows up in the node list and routes all traffic through
/// the tunnel). The WireGuard peer is emitted directly in sing-box 1.12
/// `endpoints[]` format via [_buildWireguardEndpoint] — NOT the legacy
/// `outbounds[]` form, which 1.12 rejects on `persistent_keepalive_interval`.
///
/// [persistentKeepalive] defaults to 25s (the wg-quick default). Without a
/// keepalive the peer's NAT mapping expires after a minute or two of idle and
/// the tunnel silently stops passing traffic — the classic "WireGuard keeps
/// disconnecting" symptom — so we always emit one unless the caller opts out
/// with a non-positive value.
String buildWireguardProfileConfig({
  required String server,
  required int serverPort,
  required String privateKey,
  required String peerPublicKey,
  required List<String> localAddress,
  String? preSharedKey,
  int? mtu,
  int persistentKeepalive = 25,
}) {
  const tag = 'wireguard-out';
  final outboundShaped = <String, dynamic>{
    'type': 'wireguard',
    'tag': tag,
    'server': server.trim(),
    'server_port': serverPort,
    'local_address': localAddress
        .map((address) => address.trim())
        .where((address) => address.isNotEmpty)
        .toList(growable: false),
    'private_key': privateKey.trim(),
    'peer_public_key': peerPublicKey.trim(),
  };
  final psk = preSharedKey?.trim();
  if (psk != null && psk.isNotEmpty) {
    outboundShaped['pre_shared_key'] = psk;
  }
  if (mtu != null && mtu > 0) {
    outboundShaped['mtu'] = mtu;
  }
  // Pass the value through verbatim — including 0/negative — so
  // _buildWireguardEndpoint can honor an explicit opt-out. Omitting the key
  // there would make it fall back to the 25s default.
  outboundShaped['persistent_keepalive_interval'] = persistentKeepalive;

  final endpoint = _buildWireguardEndpoint(outboundShaped);
  final config = <String, dynamic>{
    'log': <String, dynamic>{'level': 'info'},
    // Resolve DNS through the tunnel so lookups don't leak to the underlying
    // network while the full tunnel is up.
    'dns': <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'dns-remote',
          'address': '1.1.1.1',
          'detour': tag,
        },
      ],
      'strategy': 'prefer_ipv4',
    },
    'inbounds': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'tun0',
        'inet4_address': '172.19.0.1/30',
        'auto_route': true,
        'stack': 'gvisor',
        'sniff': true,
        // Match the WireGuard endpoint's 1408 MTU. Without it the TUN defaults
        // to 9000, so large packets enter the tunnel and stall against the WG
        // path MTU — reads as random "drops" on cellular/PPPoE links.
        'mtu': 1408,
      },
    ],
    'endpoints': <Map<String, dynamic>>[endpoint],
    'outbounds': <Map<String, dynamic>>[
      <String, dynamic>{'type': 'direct', 'tag': 'direct'},
    ],
    'route': <String, dynamic>{
      'auto_detect_interface': true,
      // Follow Android's current default underlying network so the tunnel's
      // own socket survives a Wi-Fi <-> cellular handover (matches the cloud
      // profile normalization in _normalizeAndroidConfig).
      'default_network_strategy': 'default',
      'final': tag,
    },
  };
  // A user-set endpoint MTU below 1408 must pull the TUN down with it.
  _clampTunMtuForWireguard(config);
  return const JsonEncoder.withIndent('  ').convert(config);
}

/// Builds a tunnel config that carries ONLY the intranet WireGuard tunnel: LAN
/// traffic goes through WireGuard, everything else goes direct (no proxy). Used
/// when the user keeps the intranet VPN on but disconnects the proxy nodes — so
/// the two run truly independently. Returns null when [wg] isn't active.
String? buildWireguardIntranetOnlyConfig(
  WireGuardIntranet wg, {
  TargetPlatform? targetPlatform,
}) {
  if (!wg.isActive) {
    return null;
  }
  final cidrs = wg.intranetCidrs;
  if (cidrs.isEmpty) {
    return null;
  }
  final config = <String, dynamic>{
    'log': <String, dynamic>{'level': 'info'},
    'dns': <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'dns-direct',
          'address': '223.5.5.5',
          'detour': 'direct',
        },
      ],
      'strategy': 'prefer_ipv4',
    },
    'inbounds': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'tun0',
        'inet4_address': '172.19.0.1/30',
        // WG-only must not install a device-wide default route. Only the
        // intranet CIDRs enter the VPN; all public traffic stays on Android's
        // underlying network even if direct DNS/protect is flaky.
        'route_address': cidrs,
        'auto_route': true,
        'stack': 'gvisor',
        'sniff': true,
        // Match the WireGuard endpoint's 1408 MTU (TUN defaults to 9000, which
        // stalls large packets against the WG path MTU — looks like "drops").
        'mtu': 1408,
      },
    ],
    'outbounds': <Map<String, dynamic>>[
      <String, dynamic>{'type': 'direct', 'tag': 'direct'},
    ],
    'route': <String, dynamic>{
      'auto_detect_interface': true,
      'default_network_strategy': 'default',
      'rules': <Map<String, dynamic>>[],
      'final': 'direct',
    },
  };
  // Inject the WireGuard endpoint + the LAN -> WireGuard rule. If the overlay
  // declines (e.g. every configured address failed to parse into a routable
  // CIDR), there is no WireGuard in this config at all — starting it would
  // bring up a direct-only tunnel that LOOKS connected but never carries the
  // LAN. Fail loudly instead.
  if (!_applyWireGuardIntranet(config, wg)) {
    return null;
  }
  // Clamp the TUN to the endpoint's effective MTU (a user-set MTU below 1408
  // must pull the TUN down with it, or mid-size packets still stall).
  _clampTunMtuForWireguard(config);
  return const JsonEncoder.withIndent('  ').convert(config);
}

/// A WireGuard endpoint's peer identity for grouping: private key + peer server
/// address + peer public key + PSK (NOT the port — see
/// [_collapseDuplicateWireguardPeers], which treats a missing port as a
/// wildcard so a port-less paste still matches a fully specified peer, while
/// two DIFFERENT explicit ports stay distinct). Returns null for non-WireGuard
/// endpoints or ones missing a key/peer address/public key. Missing and blank
/// PSK are normalized to the same value.
String? _wireguardPeerIdentity(Map endpoint) {
  if (endpoint['type']?.toString() != 'wireguard') return null;
  final pk = endpoint['private_key']?.toString().trim();
  if (pk == null || pk.isEmpty) return null;
  final peers = endpoint['peers'];
  if (peers is! List || peers.isEmpty) return null;
  final p0 = peers.first;
  if (p0 is! Map) return null;
  final addr = p0['address']?.toString().trim() ?? '';
  if (addr.isEmpty) return null; // no server address — not a groupable peer
  final peerKey = p0['public_key']?.toString().trim() ?? '';
  if (peerKey.isEmpty) return null;
  final psk = p0['pre_shared_key']?.toString().trim() ?? '';
  return '$pk|$addr|$peerKey|$psk';
}

/// Whether [allowed] already carries a full route for [cidr]'s address family
/// (`0.0.0.0/0` for IPv4, `::/0` for IPv6). Used when widening a peer's
/// allowed_ips: an IPv4 full route must NOT swallow IPv6 intranet CIDRs — the
/// route rule would send IPv6 LAN traffic to the peer but WireGuard would
/// silently drop it.
bool _allowedIpsCoverFamily(List<String> allowed, String cidr) {
  return cidr.contains(':')
      ? allowed.contains('::/0')
      : allowed.contains('0.0.0.0/0');
}

/// The peer port of a WireGuard endpoint, or null when absent.
int? _wireguardPeerPort(Map endpoint) {
  final peers = endpoint['peers'];
  if (peers is! List || peers.isEmpty) return null;
  final p0 = peers.first;
  if (p0 is! Map) return null;
  return _asIntOrNull(p0['port']);
}

/// Rewrites every reference to outbound tag [from] -> [to] across the places
/// sing-box resolves outbound tags: route.final, route.rules[].outbound, DNS
/// server detours, and selector/urltest member lists. Used after deleting a
/// duplicate endpoint so no dangling tag remains (sing-box rejects those).
bool _retargetOutboundReferences(
  Map<String, dynamic> decoded, {
  required String from,
  required String to,
}) {
  if (from == to) return false;
  var changed = false;

  final route = decoded['route'];
  if (route is Map) {
    if (route['final']?.toString() == from) {
      route['final'] = to;
      changed = true;
    }
    final rules = route['rules'];
    if (rules is List) {
      for (final r in rules.whereType<Map>()) {
        if (r['outbound']?.toString() == from) {
          r['outbound'] = to;
          changed = true;
        }
      }
    }
  }

  final dns = decoded['dns'];
  if (dns is Map) {
    final servers = dns['servers'];
    if (servers is List) {
      for (final s in servers.whereType<Map>()) {
        if (s['detour']?.toString() == from) {
          s['detour'] = to;
          changed = true;
        }
      }
    }
  }

  final outbounds = decoded['outbounds'];
  if (outbounds is List) {
    for (final o in outbounds.whereType<Map>()) {
      final members = o['outbounds'];
      if (members is List) {
        for (var i = 0; i < members.length; i++) {
          if (members[i]?.toString() == from) {
            members[i] = to;
            changed = true;
          }
        }
      }
      if (o['detour']?.toString() == from) {
        o['detour'] = to;
        changed = true;
      }
      if (o['default']?.toString() == from) {
        o['default'] = to;
        changed = true;
      }
    }
  }

  // Endpoints accept dial fields too — an endpoint dialing through another
  // tag via `detour` must not be left dangling either.
  final endpoints = decoded['endpoints'];
  if (endpoints is List) {
    for (final e in endpoints.whereType<Map>()) {
      if (e['detour']?.toString() == from) {
        e['detour'] = to;
        changed = true;
      }
    }
  }
  return changed;
}

/// Lowers every tun inbound's `mtu` to at most [maxMtu], leaving smaller
/// explicit values alone. Returns true when anything changed.
bool _clampTunMtu(Map<String, dynamic> decoded, int maxMtu) {
  final inbounds = decoded['inbounds'];
  if (inbounds is! List) return false;
  var changed = false;
  for (final inbound in inbounds.whereType<Map>()) {
    if (inbound['type']?.toString() != 'tun') continue;
    final current = _asIntOrNull(inbound['mtu']);
    if (current == null || current > maxMtu) {
      inbound['mtu'] = maxMtu;
      changed = true;
    }
  }
  return changed;
}

/// Clamps the TUN MTU to fit through the WireGuard endpoints present in the
/// config: each endpoint's effective MTU is its explicit `mtu` (sing-box
/// defaults to 1408 when absent), and the TUN must not exceed the smallest of
/// them. No-op when the config has no WireGuard endpoint. Returns true when
/// anything changed.
bool _clampTunMtuForWireguard(Map<String, dynamic> decoded) {
  final endpoints = decoded['endpoints'];
  if (endpoints is! List) return false;
  int? lowest;
  for (final e in endpoints.whereType<Map>()) {
    if (e['type']?.toString() != 'wireguard') continue;
    final mtu = _asIntOrNull(e['mtu']);
    final effective = (mtu != null && mtu > 0) ? mtu : 1408;
    if (lowest == null || effective < lowest) {
      lowest = effective;
    }
  }
  if (lowest == null) return false;
  return _clampTunMtu(decoded, lowest);
}

/// Collapses true-duplicate WireGuard endpoints (same [_wireguardPeerIdentity])
/// to a single survivor, retargeting all references onto it. Survivor priority:
/// the route.final endpoint (never demote a full tunnel), then any referenced
/// tag, then the first — so the config stays valid and only one peer dials the
/// server. Independent of the intranet overlay.
bool _collapseDuplicateWireguardPeers(Map<String, dynamic> decoded) {
  final endpoints = decoded['endpoints'];
  if (endpoints is! List || endpoints.length < 2) return false;

  final groups = <String, List<Map<String, dynamic>>>{};
  for (final e in endpoints.whereType<Map<String, dynamic>>()) {
    final id = _wireguardPeerIdentity(e);
    if (id == null) continue;
    (groups[id] ??= <Map<String, dynamic>>[]).add(e);
  }
  // A group (same key+address) is a true duplicate only if its peers don't
  // disagree on the port: a missing port is a wildcard, but two DIFFERENT
  // explicit ports are genuinely different peers and must NOT be collapsed.
  final dupGroups = groups.values.where((g) {
    if (g.length < 2) return false;
    final explicitPorts = g.map(_wireguardPeerPort).whereType<int>().toSet();
    return explicitPorts.length <= 1;
  }).toList();
  if (dupGroups.isEmpty) return false;

  final route = decoded['route'];
  final routeFinal = route is Map ? route['final']?.toString() : null;
  final referenced = <String>{};
  void addRef(dynamic t) {
    final s = t?.toString();
    if (s != null && s.isNotEmpty) referenced.add(s);
  }

  addRef(routeFinal);
  final dns = decoded['dns'];
  if (dns is Map) {
    final servers = dns['servers'];
    if (servers is List) {
      for (final s in servers.whereType<Map>()) {
        addRef(s['detour']);
      }
    }
  }
  final outbounds = decoded['outbounds'];
  if (outbounds is List) {
    for (final o in outbounds.whereType<Map>()) {
      final members = o['outbounds'];
      if (members is List) members.forEach(addRef);
      addRef(o['detour']);
      addRef(o['default']);
    }
  }
  // Endpoints can dial through another tag via `detour` too.
  for (final e in endpoints.whereType<Map>()) {
    addRef(e['detour']);
  }
  // Tags owned by NON-endpoint outbounds (direct/block/dns-out/select/auto and
  // any real outbound). If a WG endpoint's tag collides with one of these (only
  // possible in a hand-crafted import — generated configs use reserved tags),
  // retargeting its references would rewrite legitimate non-WG routing, so skip
  // collapsing that group. NB: the managed WG tags (wireguard-out /
  // wireguard-intranet) are intentionally NOT here — they are WG endpoints and
  // must collapse normally.
  final nonEndpointTags = <String>{
    'direct',
    'block',
    'dns-out',
    'select',
    'auto',
  };
  if (outbounds is List) {
    for (final o in outbounds.whereType<Map>()) {
      final t = o['tag']?.toString();
      if (t != null && t.isNotEmpty) nonEndpointTags.add(t);
    }
  }

  var changed = false;
  for (final group in dupGroups) {
    if (group.any((e) => nonEndpointTags.contains(e['tag']?.toString()))) {
      continue; // tag collides with a non-WG outbound/reserved tag — unsafe.
    }
    final survivor = group.firstWhere(
      (e) => e['tag']?.toString() == routeFinal,
      orElse: () => group.firstWhere(
        (e) => referenced.contains(e['tag']?.toString()),
        orElse: () => group.first,
      ),
    );
    final survivorTag = survivor['tag']?.toString();
    final survivorPeers = survivor['peers'];
    final survivorPeer = (survivorPeers is List && survivorPeers.isNotEmpty)
        ? survivorPeers.first
        : null;
    for (final dup in group) {
      if (identical(dup, survivor)) continue;
      final dupTag = dup['tag']?.toString();
      // Union the duplicate peer's allowed_ips into the survivor — per address
      // family (an existing 0.0.0.0/0 covers IPv4 but must not swallow IPv6
      // CIDRs) — so traffic retargeted onto the survivor isn't dropped by a
      // narrower allowed_ips than the duplicate had.
      if (survivorPeer is Map) {
        final survAllowed = _coerceStringList(survivorPeer['allowed_ips']);
        final dupPeers = dup['peers'];
        final dupPeer =
            (dupPeers is List && dupPeers.isNotEmpty) ? dupPeers.first : null;
        if (dupPeer is Map) {
          final toAdd = _coerceStringList(dupPeer['allowed_ips'])
              .where((c) => !_allowedIpsCoverFamily(survAllowed, c))
              .toList();
          if (toAdd.isNotEmpty) {
            final merged = _dedupeStrings([...survAllowed, ...toAdd]);
            if (merged.length != survAllowed.length) {
              survivorPeer['allowed_ips'] = merged;
            }
          }
        }
      }
      endpoints.remove(dup);
      changed = true;
      if (dupTag != null &&
          dupTag.isNotEmpty &&
          survivorTag != null &&
          survivorTag.isNotEmpty) {
        _retargetOutboundReferences(decoded, from: dupTag, to: survivorTag);
      }
    }
  }
  return changed;
}

/// Overlays the independent intranet WireGuard tunnel onto an already-built
/// sing-box config (proxy nodes, direct, etc.). The WireGuard peer is injected
/// as a 1.12 `endpoints[]` entry scoped (via `allowed_ips`) to the intranet
/// CIDRs, and a single highest-priority route rule sends exactly those CIDRs to
/// it. Everything else keeps flowing through the existing proxy/direct rules —
/// so the intranet tunnel and the proxy nodes run together without interfering.
/// Idempotent: re-applying replaces the prior intranet endpoint/rule.
bool _applyWireGuardIntranet(
  Map<String, dynamic> decoded,
  WireGuardIntranet wg,
) {
  if (!wg.isActive) {
    return false;
  }
  final cidrs = wg.intranetCidrs;
  if (cidrs.isEmpty) {
    return false;
  }
  const tag = WireGuardIntranet.tag;
  final ownKey = wg.privateKey.trim();
  final ownServer = wg.server.trim();

  // A WireGuard server keeps a single session per public key. If another
  // endpoint already dials THIS server with THIS local+peer keypair, the two endpoints
  // fight over that one session (each handshake evicts the other's) and the
  // tunnel keeps dropping. Identify those true duplicates precisely — same
  // private key, peer public key, PSK, and same peer server+port — so we never
  // touch an unrelated endpoint that merely reuses the client key against a
  // different server or peer identity.
  bool isSameWgPeer(Map<String, dynamic> e) {
    if (ownKey.isEmpty) return false;
    if (e['type']?.toString() != 'wireguard') return false;
    if (e['private_key']?.toString().trim() != ownKey) return false;
    final peers = e['peers'];
    if (peers is! List || peers.isEmpty) return false;
    final p0 = peers.first;
    if (p0 is! Map) return false;
    if (p0['address']?.toString().trim() != ownServer) return false;
    if (p0['public_key']?.toString().trim() != wg.peerPublicKey.trim()) {
      return false;
    }
    final peerPsk = p0['pre_shared_key']?.toString().trim() ?? '';
    final wgPsk = wg.preSharedKey?.trim() ?? '';
    if (peerPsk != wgPsk) {
      return false;
    }
    // A pasted custom outbound may omit server_port (the peer ends up with no
    // port). Same key + same server is still the same WireGuard peer, so treat
    // a missing port as a match rather than letting the duplicate slip through.
    final port = _asIntOrNull(p0['port']);
    return port == null || port == wg.serverPort;
  }

  // Tags the rest of the config structurally points at. An endpoint referenced
  // here (route.final / DNS detour / selector member) must never be deleted —
  // doing so leaves a dangling reference that sing-box rejects outright.
  final referencedTags = <String>{};
  void addRef(dynamic t) {
    final s = t?.toString();
    if (s != null && s.isNotEmpty) referencedTags.add(s);
  }

  final routeForRefs = decoded['route'];
  if (routeForRefs is Map) {
    addRef(routeForRefs['final']);
  }
  final dnsForRefs = decoded['dns'];
  if (dnsForRefs is Map) {
    final servers = dnsForRefs['servers'];
    if (servers is List) {
      for (final s in servers.whereType<Map>()) {
        addRef(s['detour']);
      }
    }
  }
  final outboundsForRefs = decoded['outbounds'];
  if (outboundsForRefs is List) {
    for (final o in outboundsForRefs.whereType<Map>()) {
      final members = o['outbounds'];
      if (members is List) {
        members.forEach(addRef);
      }
      addRef(o['detour']);
      addRef(o['default']);
    }
  }

  final endpoints = _ensureList<Map<String, dynamic>>(decoded, 'endpoints');
  // Endpoints can dial through another tag via `detour` too — such a target
  // must never be deleted out from under them.
  for (final e in endpoints) {
    addRef(e['detour']);
  }
  final route = _ensureMap(decoded, 'route');
  final routeFinal = route['final']?.toString();

  // A same-peer WireGuard endpoint that is route.final is a FULL tunnel already
  // carrying the LAN — overlaying a second same-key endpoint would only trigger
  // the session-steal drops, so skip entirely.
  if (endpoints.any((e) =>
      e['tag']?.toString() != tag &&
      e['tag']?.toString() == routeFinal &&
      isSameWgPeer(e))) {
    return false;
  }

  // NB: the TUN MTU clamp for the overlayed endpoint is NOT done here — every
  // caller runs _clampTunMtuForWireguard afterwards, which also covers the
  // early-return paths above (full-tunnel same-peer skip, legacy profiles).

  // A same-peer endpoint that is referenced elsewhere (selector member / DNS
  // detour) but is NOT the full tunnel: we can't delete it (dangling ref) and
  // must not add a duplicate. Instead REUSE it — widen its allowed_ips to cover
  // the LAN and route the intranet CIDRs to its tag — so LAN actually flows
  // through WireGuard without reintroducing a second same-key endpoint.
  final reusable = endpoints.firstWhere(
    (e) =>
        e['tag']?.toString() != tag &&
        referencedTags.contains(e['tag']?.toString()) &&
        isSameWgPeer(e),
    orElse: () => const <String, dynamic>{},
  );
  if (reusable.isNotEmpty) {
    final reuseTag = reusable['tag']!.toString();
    final peers = reusable['peers'];
    if (peers is List && peers.isNotEmpty && peers.first is Map) {
      final peer0 = peers.first as Map;
      final allowed = _coerceStringList(peer0['allowed_ips']);
      // A full-route peer already covers the LAN — per address family: an
      // IPv4-only 0.0.0.0/0 must still union in IPv6 intranet CIDRs (and vice
      // versa) or WireGuard silently drops that family's routed traffic.
      final toAdd =
          cidrs.where((c) => !_allowedIpsCoverFamily(allowed, c)).toList();
      if (toAdd.isNotEmpty) {
        peer0['allowed_ips'] = _dedupeStrings([...allowed, ...toAdd]);
      }
    }
    final rules = _ensureList<Map<String, dynamic>>(route, 'rules');
    rules.removeWhere((r) => r['outbound']?.toString() == tag);
    var at = 0;
    for (var i = 0; i < rules.length; i++) {
      final ob = rules[i]['outbound']?.toString();
      final action = rules[i]['action']?.toString();
      if (rules[i]['protocol']?.toString() == 'dns' ||
          ob == 'dns-out' ||
          ob == 'block' ||
          action == 'sniff' ||
          action == 'hijack-dns') {
        at = i + 1;
      } else {
        break;
      }
    }
    // Idempotent: don't stack a fresh LAN -> reuseTag rule on every normalize
    // pass. Only insert if an identical one isn't already present.
    final alreadyRouted = rules.any((r) =>
        r.length == 2 &&
        r['outbound']?.toString() == reuseTag &&
        _sameStringSet(r['ip_cidr'], cidrs.toSet()));
    if (!alreadyRouted) {
      rules.insert(
          at, <String, dynamic>{'ip_cidr': cidrs, 'outbound': reuseTag});
    }
    return true;
  }

  // Collapse any NON-structural same-peer duplicate (e.g. a custom-outbound WG
  // pasted into the routing-rules dialog) onto this single overlay endpoint.
  // Remember their tags so their routed CIDRs fold into the overlay and their
  // now-orphaned rules are stripped.
  final supersededTags = <String>{};
  endpoints.removeWhere((e) {
    final t = e['tag']?.toString();
    if (t == tag) return true;
    if (isSameWgPeer(e) && !referencedTags.contains(t)) {
      if (t != null && t.isNotEmpty) supersededTags.add(t);
      return true;
    }
    return false;
  });

  // Rebuild the route rules: drop the prior intranet rule and any rule pointing
  // at a superseded duplicate, but FOLD that rule's ip_cidr targets into the
  // overlay's coverage so the user's routing intent isn't silently lost (e.g. a
  // `10.0.0.0/24 -> home-wg` rule wider than the auto-derived WG subnet).
  final rules = _ensureList<Map<String, dynamic>>(route, 'rules');
  // Two separate folds, so we don't silently broaden a constrained rule:
  //  - allowedFold: every superseded ip_cidr must be permitted by the peer's
  //    allowed_ips, or WireGuard drops the packets even for retargeted rules.
  //  - broadFold: only PURE `ip_cidr -> tag` rules may widen the single broad
  //    overlay route rule. A rule with extra matchers (domain_suffix, port…)
  //    keeps its exact match by being retargeted, NOT collapsed into the broad
  //    CIDR rule (which would route its CIDR on ALL ports/domains).
  final allowedFold = <String>[];
  final broadFold = <String>[];
  final retargetedRules = <Map<String, dynamic>>[];
  rules.removeWhere((r) {
    final ob = r['outbound']?.toString();
    // Treat a stale overlay rule (ob == tag, from a prior normalize pass) the
    // SAME as a superseded-duplicate rule: fold its CIDRs back in rather than
    // dropping them. Otherwise re-normalizing loses folded coverage and the
    // output isn't idempotent (the custom CIDR a prior pass folded would be
    // silently dropped on the next pass).
    final isOwnOrSuperseded =
        ob == tag || (ob != null && supersededTags.contains(ob));
    if (!isOwnOrSuperseded) return false;
    final cidrList = _coerceStringList(r['ip_cidr']);
    allowedFold.addAll(cidrList);
    final hasOtherMatcher =
        r.keys.any((k) => k != 'ip_cidr' && k != 'outbound');
    if (hasOtherMatcher) {
      retargetedRules.add(Map<String, dynamic>.from(r)..['outbound'] = tag);
    } else {
      broadFold.addAll(cidrList);
    }
    return true;
  });
  // Dedupe retargeted rules by content so re-normalizing can't accumulate
  // identical copies of a constrained (e.g. domain_suffix/port) rule.
  final seenRetargeted = <String>{};
  retargetedRules.retainWhere((r) => seenRetargeted.add(jsonEncode(r)));
  final routeCidrs = _dedupeStrings([...cidrs, ...broadFold]);
  final allowedCidrs = _dedupeStrings([...cidrs, ...allowedFold]);

  // Build the endpoint now that the full CIDR coverage is known.
  final outboundShaped = <String, dynamic>{
    'type': 'wireguard',
    'tag': tag,
    'server': ownServer,
    'server_port': wg.serverPort,
    'local_address': wg.localAddress
        .map((address) => address.trim())
        .where((address) => address.isNotEmpty)
        .toList(growable: false),
    'private_key': ownKey,
    'peer_public_key': wg.peerPublicKey.trim(),
    // The peer must accept every routed range (broad + retargeted-constrained),
    // otherwise WireGuard drops them — but routing still scopes what arrives.
    'allowed_ips': allowedCidrs,
    // Pass keepalive through verbatim (incl. 0 = explicit opt-out); the
    // endpoint builder applies the 25s default only when the key is absent.
    'persistent_keepalive_interval': wg.persistentKeepalive,
  };
  final psk = wg.preSharedKey?.trim();
  if (psk != null && psk.isNotEmpty) {
    outboundShaped['pre_shared_key'] = psk;
  }
  if (wg.mtu != null && wg.mtu! > 0) {
    outboundShaped['mtu'] = wg.mtu;
  }
  endpoints.add(_buildWireguardEndpoint(outboundShaped));

  // Front-load the LAN -> WireGuard rule, just after any leading DNS / sniff /
  // block infrastructure rules so DNS handling is preserved but the intranet
  // rule still outranks the proxy/direct routing.
  var insertAt = 0;
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    final ob = r['outbound']?.toString();
    final action = r['action']?.toString();
    final isInfra = r['protocol']?.toString() == 'dns' ||
        ob == 'dns-out' ||
        ob == 'block' ||
        action == 'sniff' ||
        action == 'hijack-dns';
    if (isInfra) {
      insertAt = i + 1;
    } else {
      break;
    }
  }
  rules.insert(insertAt, <String, dynamic>{
    'ip_cidr': routeCidrs,
    'outbound': tag,
  });
  // Re-add any non-ip_cidr rules inherited from a collapsed duplicate, right
  // after the consolidated rule so they keep the same high priority.
  if (retargetedRules.isNotEmpty) {
    rules.insertAll(insertAt + 1, retargetedRules);
  }
  return true;
}

int? _asIntOrNull(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

Map<String, dynamic> _buildBundledRuleSet({
  required String tag,
  required String path,
}) {
  return {
    'tag': tag,
    'type': 'local',
    'format': 'binary',
    'path': path,
  };
}

Map<String, dynamic> _ensureMap(Map<String, dynamic> source, String key) {
  final existing = source[key];
  if (existing is Map<String, dynamic>) {
    return existing;
  }
  if (existing is Map) {
    final converted = Map<String, dynamic>.from(existing);
    source[key] = converted;
    return converted;
  }

  final created = <String, dynamic>{};
  source[key] = created;
  return created;
}

void _ensureManagedDnsServers(
  Map<String, dynamic> decoded, {
  required VpnRoutingSettings routingSettings,
  required bool hasDirectOutbound,
  required String? proxyOutboundTag,
}) {
  final dns = _ensureMap(decoded, 'dns');
  final servers = _ensureList<Map<String, dynamic>>(dns, 'servers');
  if (proxyOutboundTag != null) {
    _upsertDnsServer(
      servers,
      tag: _dnsRemoteTag,
      address: _dnsRemoteAddress,
      detour: proxyOutboundTag,
    );
    _upsertDnsServer(
      servers,
      tag: _dnsRemoteFallbackTag,
      address: _dnsRemoteFallbackAddress,
      detour: proxyOutboundTag,
    );
  }
  if (!hasDirectOutbound) {
    return;
  }

  _upsertDnsServer(
    servers,
    tag: _dnsBootstrapTag,
    address: _dnsBootstrapAddress,
    detour: 'direct',
  );
  _upsertDnsServer(
    servers,
    tag: _dnsLocalTag,
    address: 'local',
    detour: 'direct',
  );
  if (routingSettings.dnsMode == VpnDnsMode.regionalOptimized) {
    _upsertDnsServer(
      servers,
      tag: _dnsCnTag,
      address: _dnsCnAddress,
      detour: 'direct',
    );
  }
}

void _ensureManagedDnsDefaults(Map<String, dynamic> decoded) {
  final dns = _ensureMap(decoded, 'dns');
  if (dns['strategy']?.toString().trim() != 'prefer_ipv4') {
    dns['strategy'] = 'prefer_ipv4';
  }
  if (dns['cache_capacity'] != managedDnsCacheCapacity) {
    dns['cache_capacity'] = managedDnsCacheCapacity;
  }
  if (dns['reverse_mapping'] != true) {
    dns['reverse_mapping'] = true;
  }
}

void _upsertDnsServer(
  List<Map<String, dynamic>> servers, {
  required String tag,
  required String address,
  required String detour,
}) {
  final index =
      servers.indexWhere((server) => server['tag']?.toString() == tag);
  final next = <String, dynamic>{
    'tag': tag,
    'address': address,
    'detour': detour,
  };
  if (index == -1) {
    servers.add(next);
    return;
  }
  servers[index]
    ..['tag'] = tag
    ..['address'] = address
    ..['detour'] = detour;
}

List<T> _ensureList<T>(Map<String, dynamic> source, String key) {
  final existing = source[key];
  if (existing is List<T>) {
    return existing;
  }
  if (existing is List) {
    final converted = existing.cast<T>();
    source[key] = converted;
    return converted;
  }

  final created = <T>[];
  source[key] = created;
  return created;
}

List<Map<String, dynamic>> _coerceMapList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

Set<String> _extractProxyServerDomains(List<Map<String, dynamic>> outbounds) {
  final domains = <String>{};
  for (final outbound in outbounds) {
    final server = outbound['server']?.toString().trim();
    if (server == null ||
        server.isEmpty ||
        server == 'localhost' ||
        InternetAddress.tryParse(server) != null) {
      continue;
    }
    domains.add(server);
  }
  return domains;
}

String _resolveDirectDnsServerTag(VpnRoutingSettings routingSettings) {
  return switch (routingSettings.dnsMode) {
    VpnDnsMode.regionalOptimized => _dnsCnTag,
    VpnDnsMode.systemResolver => _dnsLocalTag,
    VpnDnsMode.strictProxy => _dnsBootstrapTag,
  };
}

String _resolveDefaultDnsServerTag(
  VpnRoutingSettings routingSettings, {
  required bool hasDirectOutbound,
  required String? proxyOutboundTag,
}) {
  switch (routingSettings.dnsMode) {
    case VpnDnsMode.regionalOptimized:
    case VpnDnsMode.strictProxy:
      return proxyOutboundTag != null ? _dnsRemoteTag : _dnsLocalTag;
    case VpnDnsMode.systemResolver:
      return hasDirectOutbound ? _dnsLocalTag : _dnsRemoteTag;
  }
}

void _ensureBlockOutbound(List outbounds) {
  final hasBlock = outbounds.whereType<Map>().any((outbound) {
    final tag = outbound['tag']?.toString().trim();
    return tag == 'block';
  });
  if (hasBlock) {
    return;
  }
  outbounds.add({
    'type': 'block',
    'tag': 'block',
  });
}

List<String> _extractTunSubnetCidrs(Map<String, dynamic> decoded) {
  final inbounds = decoded['inbounds'];
  if (inbounds is! List) {
    return const [];
  }

  final cidrs = <String>[];
  for (final inbound in inbounds.whereType<Map>()) {
    if (inbound['type']?.toString().trim() != 'tun') {
      continue;
    }
    _appendTunSubnetCidrs(cidrs, inbound['inet4_address']);
    _appendTunSubnetCidrs(cidrs, inbound['inet6_address']);
  }
  return _dedupeStrings(cidrs);
}

void _appendTunSubnetCidrs(List<String> cidrs, dynamic rawValue) {
  if (rawValue is String) {
    final normalized = _normalizeTunSubnetCidr(rawValue);
    if (normalized != null) {
      cidrs.add(normalized);
    }
    return;
  }
  if (rawValue is List) {
    for (final value in rawValue.whereType<String>()) {
      final normalized = _normalizeTunSubnetCidr(value);
      if (normalized != null) {
        cidrs.add(normalized);
      }
    }
  }
}

String? _normalizeTunSubnetCidr(String cidr) {
  final trimmed = cidr.trim();
  if (trimmed.isEmpty || !trimmed.contains('/')) {
    return null;
  }

  final separatorIndex = trimmed.indexOf('/');
  final address = trimmed.substring(0, separatorIndex).trim();
  final prefixLength =
      int.tryParse(trimmed.substring(separatorIndex + 1).trim());
  if (prefixLength == null) {
    return trimmed;
  }

  final octets = address.split('.');
  if (octets.length != 4 || prefixLength < 0 || prefixLength > 32) {
    return trimmed;
  }

  final parsedOctets = <int>[];
  for (final octet in octets) {
    final value = int.tryParse(octet);
    if (value == null || value < 0 || value > 255) {
      return trimmed;
    }
    parsedOctets.add(value);
  }

  final addressValue = (parsedOctets[0] << 24) |
      (parsedOctets[1] << 16) |
      (parsedOctets[2] << 8) |
      parsedOctets[3];
  final mask =
      prefixLength == 0 ? 0 : (0xffffffff << (32 - prefixLength)) & 0xffffffff;
  final networkValue = addressValue & mask;
  return '${(networkValue >> 24) & 0xff}.'
      '${(networkValue >> 16) & 0xff}.'
      '${(networkValue >> 8) & 0xff}.'
      '${networkValue & 0xff}/$prefixLength';
}

bool _containsAndroidPrivateDnsCompatRule(
  List<Map<String, dynamic>> rules,
  List<String> probeCidrs,
) {
  final expectedCidrs = probeCidrs.toSet();
  for (final rule in rules) {
    if (rule['outbound']?.toString().trim() != 'block') {
      continue;
    }
    if (rule['network']?.toString().trim().toLowerCase() != 'tcp') {
      continue;
    }
    if (!_matchesPort(rule['port'], _androidTunDnsTlsPort)) {
      continue;
    }
    final cidrs = _coerceStringList(rule['ip_cidr']).toSet();
    if (expectedCidrs.every(cidrs.contains)) {
      return true;
    }
  }
  return false;
}

List<String> _coerceStringList(dynamic value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }
  if (value is List) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}

bool _matchesPort(dynamic value, int expectedPort) {
  if (value is int) {
    return value == expectedPort;
  }
  if (value is String) {
    return value.trim() == expectedPort.toString();
  }
  if (value is List) {
    return value.any((item) => _matchesPort(item, expectedPort));
  }
  return false;
}

String? _selectProxyOutboundTag({
  required String? routeFinal,
  required List<Map<String, dynamic>> outbounds,
  required Set<String> outboundTags,
}) {
  final preferredTag = routeFinal?.trim();
  if (preferredTag != null && _isProxyOutboundTag(preferredTag, outboundTags)) {
    return preferredTag;
  }
  if (outboundTags.contains('select')) {
    return 'select';
  }
  if (outboundTags.contains('auto')) {
    return 'auto';
  }

  for (final outbound in outbounds) {
    final tag = outbound['tag']?.toString().trim();
    if (tag == null || tag.isEmpty) {
      continue;
    }
    if (!_isProxyOutboundTag(tag, outboundTags)) {
      continue;
    }
    return tag;
  }
  return null;
}

bool _isProxyOutboundTag(String tag, Set<String> outboundTags) {
  return outboundTags.contains(tag) &&
      tag != 'direct' &&
      tag != 'dns-out' &&
      tag != 'block';
}

bool _isManagedOrLegacyRule(Map<String, dynamic> rule) {
  final outbound = rule['outbound']?.toString();
  final protocol = rule['protocol']?.toString();
  if (protocol == 'dns' && outbound == 'dns-out') {
    return true;
  }
  if (rule.containsKey('package_name')) {
    return true;
  }
  if (rule['ip_is_private'] == true && outbound == 'direct') {
    return true;
  }

  final geoip = rule['geoip'];
  if (outbound == 'direct' &&
      (geoip == 'private' ||
          (geoip is List &&
              geoip.any((value) => value?.toString() == 'private')))) {
    return true;
  }

  if (outbound == 'direct' && _isCloudProviderApiBypassRule(rule)) {
    return true;
  }

  final ruleSet = rule['rule_set'];
  if (ruleSet == _managedGeositeCnTag || ruleSet == _managedGeoipCnTag) {
    return true;
  }
  return false;
}

bool _isManagedDnsRule(Map<String, dynamic> rule) {
  final server = rule['server']?.toString().trim();
  final ruleSet = rule['rule_set']?.toString().trim();
  if (_isCatchAllDnsRule(rule)) {
    return true;
  }
  if (server == _dnsBootstrapTag && _isCloudProviderApiDnsBypassRule(rule)) {
    return true;
  }
  // The managed remote-fallback suffix rule is re-emitted for every proxy
  // config; recognize it so re-normalizing treats it as managed (rebuilt) and
  // doesn't preserve+accumulate a duplicate each pass (config-churn / breaks
  // idempotency). Matched by tag + the exact managed suffix set.
  if (server == _dnsRemoteFallbackTag &&
      _sameStringSet(rule['domain_suffix'],
          managedDnsRemoteFallbackDomainSuffixes.toSet())) {
    return true;
  }
  if (ruleSet == _managedGeositeCnTag &&
      (server == _dnsCnTag || server == _dnsLocalTag)) {
    return true;
  }
  return false;
}

bool _isCatchAllDnsRule(Map<String, dynamic> rule) {
  final outbounds = rule['outbound'];
  if (outbounds is! List) {
    return false;
  }
  return outbounds.any((value) => value?.toString() == 'any');
}

// Recognize the PD-managed cloud-API bypass rule under both shapes:
//   - legacy: ["api.vultr.com", "api.digitalocean.com"]
//   - current: ["api.vultr.com", "api.digitalocean.com", "api.cloudflare.com"]
// Accept any subset of [_cloudProviderApiDomains] that contains the legacy
// core. False positives stay impossible: arbitrary user rules with other
// domains mixed in will violate the subset constraint.
bool _isCloudProviderApiBypassRule(Map<String, dynamic> rule) {
  final suffixes = rule['domain_suffix'];
  if (suffixes is! List) {
    return false;
  }
  final set = suffixes.map((e) => e?.toString()).toSet();
  return set.containsAll(_cloudProviderApiCoreDomains) &&
      _cloudProviderApiDomains.toSet().containsAll(set);
}

bool _isCloudProviderApiDnsBypassRule(Map<String, dynamic> rule) {
  final suffixes = rule['domain_suffix'];
  if (suffixes is! List) {
    return false;
  }
  final set = suffixes.map((e) => e?.toString()).toSet();
  return set.containsAll(_cloudProviderApiCoreDomains) &&
      _cloudProviderApiDomains.toSet().containsAll(set);
}

bool _isManagedRuleSet(Map<String, dynamic> ruleSet) {
  final tag = ruleSet['tag']?.toString();
  return tag == _managedGeositeCnTag || tag == _managedGeoipCnTag;
}

void _appendDomainSuffixRule(
  List<Map<String, dynamic>> rules,
  List<String> domains,
  String outboundTag,
) {
  final normalizedDomains = _dedupeStrings(
    domains.map((domain) => domain.trim().toLowerCase()),
  );
  if (normalizedDomains.isEmpty) {
    return;
  }
  rules.add({
    'domain_suffix': normalizedDomains,
    'outbound': outboundTag,
  });
}

void _appendDnsDomainSuffixRule(
  List<Map<String, dynamic>> rules,
  List<String> domains,
  String serverTag,
) {
  final normalizedDomains = _dedupeStrings(
    domains.map((domain) => domain.trim().toLowerCase()),
  );
  if (normalizedDomains.isEmpty) {
    return;
  }
  rules.add({
    'domain_suffix': normalizedDomains,
    'server': serverTag,
  });
}

void _appendDnsDomainRule(
  List<Map<String, dynamic>> rules,
  List<String> domains,
  String serverTag,
) {
  final normalizedDomains = _dedupeStrings(
    domains.map((domain) => domain.trim().toLowerCase()),
  );
  if (normalizedDomains.isEmpty) {
    return;
  }
  rules.add({
    'domain': normalizedDomains,
    'server': serverTag,
  });
}

void _appendPackageRule(
  List<Map<String, dynamic>> rules,
  List<String> packageNames,
  String outboundTag,
) {
  final normalizedPackages = _dedupeStrings(
    packageNames.map((packageName) => packageName.trim()),
  );
  if (normalizedPackages.isEmpty) {
    return;
  }
  rules.add({
    'package_name': normalizedPackages,
    'outbound': outboundTag,
  });
}

void _appendIpCidrRule(
  List<Map<String, dynamic>> rules,
  List<String> cidrs,
  String outboundTag,
) {
  final normalizedCidrs = _dedupeStrings(
    cidrs.map((cidr) => cidr.trim()),
  );
  if (normalizedCidrs.isEmpty) {
    return;
  }
  rules.add({
    'ip_cidr': normalizedCidrs,
    'outbound': outboundTag,
  });
}

List<String> _dedupeStrings(Iterable<String> values) {
  final unique = <String>{};
  final deduped = <String>[];
  for (final value in values) {
    if (value.isEmpty || unique.contains(value)) {
      continue;
    }
    unique.add(value);
    deduped.add(value);
  }
  return deduped;
}

bool isUnsupportedAndroidOutbound(Map<String, dynamic> outbound) {
  // Let the Android runtime decide whether an outbound is usable instead of
  // pre-stripping protocols from the profile. This keeps cloud-generated and
  // imported configs intact, even when they contain newer protocol features.
  return false;
}
