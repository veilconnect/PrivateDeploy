import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/app_settings_provider.dart';
import 'bundled_rule_set_registry.dart';

const _managedGeositeCnTag = 'pd-geosite-cn';
const _managedGeoipCnTag = 'pd-geoip-cn';

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

    var changed = false;
    if ((targetPlatform ?? defaultTargetPlatform) == TargetPlatform.android) {
      changed = _normalizeAndroidConfig(decoded) || changed;
    }
    changed =
        _applyRoutingSettings(decoded, routingSettings, bundledRuleSetPaths) ||
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

bool _applyRoutingSettings(
  Map<String, dynamic> decoded,
  VpnRoutingSettings routingSettings,
  BundledRuleSetPaths bundledRuleSetPaths,
) {
  final originalJson = jsonEncode(decoded);
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) {
    return false;
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

  final preservedRules = _coerceMapList(route['rules'])
      .where((rule) => !_isManagedOrLegacyRule(rule))
      .toList(growable: false);
  final managedRules = <Map<String, dynamic>>[];

  if (hasDnsOutbound) {
    managedRules.add({
      'protocol': 'dns',
      'outbound': 'dns-out',
    });
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

  return originalJson != jsonEncode(decoded);
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
