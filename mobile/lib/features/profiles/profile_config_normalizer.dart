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
  peer['allowed_ips'] = const ['0.0.0.0/0', '::/0'];
  final keepalive = _asIntOrNull(outbound['persistent_keepalive_interval']);
  if (keepalive != null && keepalive > 0) {
    peer['persistent_keepalive_interval'] = keepalive;
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
