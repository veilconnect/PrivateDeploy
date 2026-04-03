import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/app_settings_provider.dart';
import 'bundled_rule_set_registry.dart';

const _managedGeositeCnTag = 'pd-geosite-cn';
const _managedGeoipCnTag = 'pd-geoip-cn';
const _androidTunDnsTlsPort = 853;

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

  final inbounds = decoded['inbounds'];
  if (inbounds is List) {
    for (final inbound in inbounds) {
      if (inbound is! Map<String, dynamic>) {
        continue;
      }
      if (inbound['type']?.toString() != 'tun') {
        continue;
      }

      final stack = inbound['stack']?.toString().trim();
      if (stack == null || stack.isEmpty || stack == 'system') {
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

  return changed;
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
  if (tunSubnetCidrs.isNotEmpty) {
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

  final hasDirectOutbound = outboundTags.contains('direct');
  final hasDnsOutbound = outboundTags.contains('dns-out');
  final route = _ensureMap(decoded, 'route');
  final proxyOutboundTag = _selectProxyOutboundTag(
    routeFinal: route['final']?.toString(),
    outbounds: outboundMaps.toList(growable: false),
    outboundTags: outboundTags,
  );

  final existingRules = _coerceMapList(route['rules']);
  final preservedRules = existingRules
      .where((rule) => !_isManagedOrLegacyRule(rule))
      .toList(growable: false);
  final managedRules = <Map<String, dynamic>>[];

  if (tunSubnetCidrs.isNotEmpty &&
      outboundTags.contains('block') &&
      !_containsAndroidTunDnsCompatRule(existingRules, tunSubnetCidrs)) {
    managedRules.add({
      'network': 'tcp',
      'port': _androidTunDnsTlsPort,
      'ip_cidr': tunSubnetCidrs,
      'outbound': 'block',
    });
  }

  if (hasDnsOutbound) {
    managedRules.add({
      'protocol': 'dns',
      'outbound': 'dns-out',
    });
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
      routingSettings.customDirectPackages,
      'direct',
    );
  }

  if (hasDirectOutbound && routingSettings.directPrivateNetworks) {
    managedRules.add({
      'ip_is_private': true,
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
    routingSettings.customDirectPackages.map((p) => p.trim()),
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

List<Map<String, dynamic>> _coerceMapList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
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

bool _containsAndroidTunDnsCompatRule(
  List<Map<String, dynamic>> rules,
  List<String> tunSubnetCidrs,
) {
  final expectedCidrs = tunSubnetCidrs.toSet();
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

  final ruleSet = rule['rule_set'];
  if (ruleSet == _managedGeositeCnTag || ruleSet == _managedGeoipCnTag) {
    return true;
  }
  return false;
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
  final type = outbound['type']?.toString();
  if (type == 'hysteria2') {
    return true;
  }
  if (type != 'vless') {
    return false;
  }

  final tls = outbound['tls'];
  if (tls is! Map) {
    return false;
  }

  return isFeatureEnabled(tls['utls']) || isFeatureEnabled(tls['reality']);
}

bool isFeatureEnabled(dynamic value) {
  if (value is Map) {
    final enabled = value['enabled'];
    if (enabled is bool) {
      return enabled;
    }
    return enabled?.toString().toLowerCase() == 'true';
  }
  return false;
}
