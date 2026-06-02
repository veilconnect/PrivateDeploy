import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/storage/storage_service.dart';
import '../../l10n/app_localizations.dart';

enum VpnRoutingMode {
  split,
  global,
}

enum VpnDnsMode {
  regionalOptimized,
  strictProxy,
  systemResolver,
}

const defaultAndroidChinaDirectPackages = [
  'com.tencent.mm',
  'com.tencent.mobileqq',
  'com.tencent.wework',
  'com.tencent.qqmusic',
  'com.tencent.qqlive',
  'com.tencent.news',
  'com.eg.android.AlipayGphone',
  'com.alibaba.android.rimet',
  'com.taobao.taobao',
  'com.tmall.wireless',
  'com.jingdong.app.mall',
  'com.xunmeng.pinduoduo',
  'com.sankuai.meituan',
  'com.sankuai.meituan.takeoutnew',
  'com.dianping.v1',
  'me.ele',
  'com.autonavi.minimap',
  'com.baidu.BaiduMap',
  'com.didi.passenger',
  'ctrip.android.view',
  'com.MobileTicket',
  'com.ss.android.ugc.aweme',
  'com.ss.android.ugc.live',
  'com.kuaishou.nebula',
  'tv.danmaku.bili',
  'com.xingin.xhs',
  'com.sina.weibo',
  'com.zhihu.android',
  'com.netease.cloudmusic',
  'com.unionpay',
];

const defaultAndroidChinaDirectPackageLabels = {
  'com.tencent.mm': 'WeChat',
  'com.tencent.mobileqq': 'QQ',
  'com.tencent.wework': 'WeCom',
  'com.tencent.qqmusic': 'QQ Music',
  'com.tencent.qqlive': 'Tencent Video',
  'com.tencent.news': 'Tencent News',
  'com.eg.android.AlipayGphone': 'Alipay',
  'com.alibaba.android.rimet': 'DingTalk',
  'com.taobao.taobao': 'Taobao',
  'com.tmall.wireless': 'Tmall',
  'com.jingdong.app.mall': 'JD',
  'com.xunmeng.pinduoduo': 'Pinduoduo',
  'com.sankuai.meituan': 'Meituan',
  'com.sankuai.meituan.takeoutnew': 'Meituan Waimai',
  'com.dianping.v1': 'Dianping',
  'me.ele': 'Ele.me',
  'com.autonavi.minimap': 'AMap',
  'com.baidu.BaiduMap': 'Baidu Maps',
  'com.didi.passenger': 'DiDi',
  'ctrip.android.view': 'Trip.com',
  'com.MobileTicket': '12306',
  'com.ss.android.ugc.aweme': 'Douyin',
  'com.ss.android.ugc.live': 'Douyin Live',
  'com.kuaishou.nebula': 'Kuaishou',
  'tv.danmaku.bili': 'Bilibili',
  'com.xingin.xhs': 'RED',
  'com.sina.weibo': 'Weibo',
  'com.zhihu.android': 'Zhihu',
  'com.netease.cloudmusic': 'NetEase Music',
  'com.unionpay': 'UnionPay',
};

const vpnDiagnosticsPinnedBypassPackages = [
  'com.tencent.mm',
  'com.eg.android.AlipayGphone',
  'com.autonavi.minimap',
  'com.taobao.taobao',
  'com.jingdong.app.mall',
  'com.ss.android.ugc.aweme',
  'tv.danmaku.bili',
  'com.sina.weibo',
];

@immutable
class VpnRoutingSettings {
  const VpnRoutingSettings({
    this.mode = VpnRoutingMode.split,
    this.dnsMode = VpnDnsMode.regionalOptimized,
    this.directPrivateNetworks = true,
    this.directCnDomains = true,
    this.directCnIpRanges = true,
    this.customDirectPackages = const [],
    this.customProxyPackages = const [],
    this.customDirectDomains = const [],
    this.customProxyDomains = const [],
    this.customDirectCidrs = const [],
    this.customProxyCidrs = const [],
  });

  final VpnRoutingMode mode;
  final VpnDnsMode dnsMode;
  final bool directPrivateNetworks;
  final bool directCnDomains;
  final bool directCnIpRanges;
  final List<String> customDirectPackages;
  final List<String> customProxyPackages;
  final List<String> customDirectDomains;
  final List<String> customProxyDomains;
  final List<String> customDirectCidrs;
  final List<String> customProxyCidrs;

  static const defaults = VpnRoutingSettings();

  bool get isSplitMode => mode == VpnRoutingMode.split;

  String get modeLabel => isSplitMode ? 'Split' : 'Global';

  String get dnsModeLabel {
    return switch (dnsMode) {
      VpnDnsMode.regionalOptimized => 'regional optimized DNS',
      VpnDnsMode.strictProxy => 'Strict proxy DNS',
      VpnDnsMode.systemResolver => 'System DNS',
    };
  }

  String get summary {
    if (mode == VpnRoutingMode.global) {
      final customCount = customDirectDomains.length +
          customDirectPackages.length +
          customProxyDomains.length +
          customProxyPackages.length +
          customDirectCidrs.length +
          customProxyCidrs.length;
      if (customCount == 0) {
        return 'All traffic via VPN, LAN bypassed · $dnsModeLabel';
      }
      return 'All traffic via VPN, LAN bypassed, $customCount custom rule(s) · $dnsModeLabel';
    }

    final enabledBuiltins = <String>[
      if (directPrivateNetworks) 'LAN direct',
      'regional apps direct',
      if (directCnDomains) 'CN domains direct',
      if (directCnIpRanges) 'CN IPs direct',
      dnsModeLabel,
    ];
    final customCount = customDirectDomains.length +
        customDirectPackages.length +
        customProxyDomains.length +
        customProxyPackages.length +
        customDirectCidrs.length +
        customProxyCidrs.length;
    final builtinText = enabledBuiltins.isEmpty
        ? 'No built-in rules enabled'
        : enabledBuiltins.join(' · ');
    if (customCount == 0) {
      return builtinText;
    }
    return '$builtinText · $customCount custom rule(s)';
  }

  /// Localized variant of [summary] for display in the settings UI.
  String localizedSummary(AppLocalizations l10n) {
    final dnsLabel = switch (dnsMode) {
      VpnDnsMode.regionalOptimized => l10n.cnOptimizedDns,
      VpnDnsMode.strictProxy => l10n.strictProxyDns,
      VpnDnsMode.systemResolver => l10n.systemDns,
    };
    final customCount = customDirectDomains.length +
        customDirectPackages.length +
        customProxyDomains.length +
        customProxyPackages.length +
        customDirectCidrs.length +
        customProxyCidrs.length;

    if (mode == VpnRoutingMode.global) {
      if (customCount == 0) {
        return l10n.routingSummaryGlobal(dnsLabel);
      }
      return l10n.routingSummaryGlobalWithCustom(customCount, dnsLabel);
    }

    final enabledBuiltins = <String>[
      if (directPrivateNetworks) l10n.routingTagLanDirect,
      l10n.routingTagCnAppsDirect,
      if (directCnDomains) l10n.routingTagCnDomainsDirect,
      if (directCnIpRanges) l10n.routingTagCnIpsDirect,
      dnsLabel,
    ];
    final builtinText = enabledBuiltins.isEmpty
        ? l10n.routingSummaryNoBuiltins
        : enabledBuiltins.join(' · ');
    if (customCount == 0) {
      return builtinText;
    }
    return l10n.routingSummaryWithCustom(builtinText, customCount);
  }

  VpnRoutingSettings copyWith({
    VpnRoutingMode? mode,
    VpnDnsMode? dnsMode,
    bool? directPrivateNetworks,
    bool? directCnDomains,
    bool? directCnIpRanges,
    List<String>? customDirectPackages,
    List<String>? customProxyPackages,
    List<String>? customDirectDomains,
    List<String>? customProxyDomains,
    List<String>? customDirectCidrs,
    List<String>? customProxyCidrs,
  }) {
    return VpnRoutingSettings(
      mode: mode ?? this.mode,
      dnsMode: dnsMode ?? this.dnsMode,
      directPrivateNetworks:
          directPrivateNetworks ?? this.directPrivateNetworks,
      directCnDomains: directCnDomains ?? this.directCnDomains,
      directCnIpRanges: directCnIpRanges ?? this.directCnIpRanges,
      customDirectPackages: customDirectPackages ?? this.customDirectPackages,
      customProxyPackages: customProxyPackages ?? this.customProxyPackages,
      customDirectDomains: customDirectDomains ?? this.customDirectDomains,
      customProxyDomains: customProxyDomains ?? this.customProxyDomains,
      customDirectCidrs: customDirectCidrs ?? this.customDirectCidrs,
      customProxyCidrs: customProxyCidrs ?? this.customProxyCidrs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'dnsMode': dnsMode.name,
      'directPrivateNetworks': directPrivateNetworks,
      'directCnDomains': directCnDomains,
      'directCnIpRanges': directCnIpRanges,
      'customDirectPackages': customDirectPackages,
      'customProxyPackages': customProxyPackages,
      'customDirectDomains': customDirectDomains,
      'customProxyDomains': customProxyDomains,
      'customDirectCidrs': customDirectCidrs,
      'customProxyCidrs': customProxyCidrs,
    };
  }

  factory VpnRoutingSettings.fromJson(Map<String, dynamic> json) {
    VpnRoutingMode parseMode(dynamic value) {
      final raw = value?.toString();
      return VpnRoutingMode.values
              .where((item) => item.name == raw)
              .firstOrNull ??
          VpnRoutingMode.split;
    }

    VpnDnsMode parseDnsMode(dynamic value) {
      final raw = value?.toString();
      return VpnDnsMode.values.where((item) => item.name == raw).firstOrNull ??
          VpnDnsMode.regionalOptimized;
    }

    List<String> parseList(dynamic value) {
      if (value is List) {
        return value
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }

    return VpnRoutingSettings(
      mode: parseMode(json['mode']),
      dnsMode: parseDnsMode(json['dnsMode']),
      directPrivateNetworks: json['directPrivateNetworks'] != false,
      directCnDomains: json['directCnDomains'] != false,
      directCnIpRanges: json['directCnIpRanges'] != false,
      customDirectPackages: parseList(json['customDirectPackages']),
      customProxyPackages: parseList(json['customProxyPackages']),
      customDirectDomains: parseList(json['customDirectDomains']),
      customProxyDomains: parseList(json['customProxyDomains']),
      customDirectCidrs: parseList(json['customDirectCidrs']),
      customProxyCidrs: parseList(json['customProxyCidrs']),
    );
  }
}

String? validateVpnRoutingDomain(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'Domain cannot be empty';
  }
  if (normalized.contains('://') ||
      normalized.contains('/') ||
      normalized.contains(' ') ||
      normalized.contains(':')) {
    return 'Use a domain or suffix only, without scheme, path or port';
  }
  if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(normalized)) {
    return 'Invalid domain format: $value';
  }
  return null;
}

String? validateVpnRoutingCidr(String value) {
  final normalized = value.trim();
  final match = RegExp(r'^([^/]+)/(\d{1,3})$').firstMatch(normalized);
  if (match == null) {
    return 'Invalid CIDR format: $value';
  }

  final host = match.group(1);
  final prefix = int.tryParse(match.group(2)!);
  if (host == null || prefix == null) {
    return 'Invalid CIDR format: $value';
  }

  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return 'Invalid CIDR address: $value';
  }

  final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
  if (prefix < 0 || prefix > maxPrefix) {
    return 'Invalid CIDR prefix: $value';
  }
  return null;
}

String? validateVpnRoutingPackageName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return 'App package cannot be empty';
  }
  if (normalized.contains(' ')) {
    return 'App package cannot contain spaces';
  }
  if (!RegExp(r'^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$').hasMatch(normalized)) {
    return 'Invalid app package: $value';
  }
  return null;
}

List<String> effectiveAndroidDirectPackages(VpnRoutingSettings settings) {
  final customDirectPackages = settings.customDirectPackages
      .map((packageName) => packageName.trim())
      .toList(growable: false);
  if (settings.mode != VpnRoutingMode.split) {
    return _subtractPackages(
      _dedupeStrings(customDirectPackages),
      settings.customProxyPackages,
    );
  }

  return _subtractPackages(
    _dedupeStrings([
      ...defaultAndroidChinaDirectPackages,
      ...customDirectPackages,
    ]),
    settings.customProxyPackages,
  );
}

List<String> previewAndroidDirectPackages(
  VpnRoutingSettings settings, {
  int maxItems = 8,
}) {
  final packages = effectiveAndroidDirectPackages(settings);
  if (packages.length <= maxItems) {
    return packages;
  }

  final packageSet = packages.toSet();
  final ordered = <String>[
    ...vpnDiagnosticsPinnedBypassPackages.where(packageSet.contains),
    ...packages.where(
      (packageName) =>
          !vpnDiagnosticsPinnedBypassPackages.contains(packageName),
    ),
  ];
  return ordered.take(maxItems).toList(growable: false);
}

String displayNameForVpnRoutingPackage(String packageName) {
  final normalized = packageName.trim();
  if (normalized.isEmpty) {
    return normalized;
  }
  return defaultAndroidChinaDirectPackageLabels[normalized] ?? normalized;
}

List<String> _dedupeStrings(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    result.add(normalized);
  }
  return result;
}

List<String> _subtractPackages(
  List<String> packages,
  List<String> excludedPackages,
) {
  if (packages.isEmpty || excludedPackages.isEmpty) {
    return packages;
  }

  final excluded = excludedPackages
      .map((packageName) => packageName.trim())
      .where((packageName) => packageName.isNotEmpty)
      .toSet();
  if (excluded.isEmpty) {
    return packages;
  }

  return packages
      .where((packageName) => !excluded.contains(packageName))
      .toList(growable: false);
}

class AppSettingsProvider with ChangeNotifier {
  static const String _vpnRoutingSettingsKey = 'mobile_vpn_routing_settings';

  VpnRoutingSettings _vpnRoutingSettings = VpnRoutingSettings.defaults;

  AppSettingsProvider() {
    _load();
  }

  VpnRoutingSettings get vpnRoutingSettings => _vpnRoutingSettings;

  Future<void> setVpnRoutingMode(VpnRoutingMode mode) async {
    await updateVpnRoutingSettings(_vpnRoutingSettings.copyWith(mode: mode));
  }

  Future<void> updateVpnRoutingSettings(VpnRoutingSettings settings) async {
    _vpnRoutingSettings = settings;
    await _persist();
    notifyListeners();
  }

  Future<void> resetVpnRoutingSettings() async {
    await updateVpnRoutingSettings(VpnRoutingSettings.defaults);
  }

  void _load() {
    final raw = StorageService.getString(_vpnRoutingSettingsKey);
    if (raw == null || raw.trim().isEmpty) {
      _vpnRoutingSettings = VpnRoutingSettings.defaults;
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _vpnRoutingSettings = VpnRoutingSettings.fromJson(decoded);
        return;
      }
    } catch (_) {}

    _vpnRoutingSettings = VpnRoutingSettings.defaults;
  }

  Future<void> _persist() async {
    if (!StorageService.isInitialized) {
      await StorageService.init();
    }
    await StorageService.saveString(
      _vpnRoutingSettingsKey,
      jsonEncode(_vpnRoutingSettings.toJson()),
    );
  }
}
