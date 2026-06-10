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

/// Matcher type for a user-defined custom routing rule.
enum CustomRuleMatcher {
  domainSuffix,
  ipCidr,
}

/// A user-defined routing rule that sends traffic matching [value] to the
/// outbound tagged [outbound]. Unlike the built-in customDirect/customProxy
/// lists, [outbound] can target any outbound tag, including a user-defined
/// custom outbound (e.g. a WireGuard tunnel to a private network).
@immutable
class CustomRoutingRule {
  const CustomRoutingRule({
    required this.matcher,
    required this.value,
    required this.outbound,
  });

  final CustomRuleMatcher matcher;
  final String value;
  final String outbound;

  CustomRoutingRule copyWith({
    CustomRuleMatcher? matcher,
    String? value,
    String? outbound,
  }) {
    return CustomRoutingRule(
      matcher: matcher ?? this.matcher,
      value: value ?? this.value,
      outbound: outbound ?? this.outbound,
    );
  }

  Map<String, dynamic> toJson() => {
        'matcher': matcher.name,
        'value': value,
        'outbound': outbound,
      };

  factory CustomRoutingRule.fromJson(Map<String, dynamic> json) {
    final rawMatcher = json['matcher']?.toString();
    final matcher = CustomRuleMatcher.values
            .where((item) => item.name == rawMatcher)
            .firstOrNull ??
        CustomRuleMatcher.domainSuffix;
    return CustomRoutingRule(
      matcher: matcher,
      value: json['value']?.toString().trim() ?? '',
      outbound: json['outbound']?.toString().trim() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomRoutingRule &&
      other.matcher == matcher &&
      other.value == value &&
      other.outbound == outbound;

  @override
  int get hashCode => Object.hash(matcher, value, outbound);
}

@immutable
/// Independent "intranet VPN" overlay: a WireGuard tunnel that runs *alongside*
/// the proxy nodes inside the same sing-box instance, but only claims traffic
/// destined for the private LAN behind the WireGuard server. It is controlled
/// separately from the proxy node selection (its own enable switch), so the
/// user can run WireGuard-only, proxy-only, or both at once without the two
/// interfering: intranet CIDRs -> WireGuard, blocked traffic -> proxy nodes,
/// everything else -> direct.
@immutable
class WireGuardIntranet {
  const WireGuardIntranet({
    this.enabled = false,
    this.server = '',
    this.serverPort = 0,
    this.privateKey = '',
    this.peerPublicKey = '',
    this.localAddress = const [],
    this.preSharedKey,
    this.mtu,
    this.persistentKeepalive = 25,
    this.extraCidrs = const [],
  });

  /// Reserved outbound/endpoint tag for the intranet WireGuard tunnel. Distinct
  /// from the standalone full-tunnel `wireguard-out` so the two never collide.
  static const tag = 'wireguard-intranet';

  static const defaults = WireGuardIntranet();

  final bool enabled;
  final String server;
  final int serverPort;
  final String privateKey;
  final String peerPublicKey;

  /// Local interface address(es), e.g. `['10.8.0.2/24']`. The subnet of each
  /// entry is auto-routed through WireGuard (see [intranetCidrs]).
  final List<String> localAddress;
  final String? preSharedKey;
  final int? mtu;
  final int persistentKeepalive;

  /// Extra LAN ranges to route through WireGuard in addition to the WG subnet,
  /// e.g. `['192.168.1.0/24', '10.0.0.0/8']`.
  final List<String> extraCidrs;

  bool get isConfigured =>
      server.trim().isNotEmpty &&
      serverPort > 0 &&
      privateKey.trim().isNotEmpty &&
      peerPublicKey.trim().isNotEmpty &&
      localAddress.any((a) => a.trim().isNotEmpty);

  /// The overlay only injects into the config when both enabled and complete.
  bool get isActive => enabled && isConfigured;

  /// Destination CIDRs that should be routed through WireGuard: the network of
  /// each local address (auto) plus any user-supplied [extraCidrs], deduped.
  List<String> get intranetCidrs {
    final out = <String>[];
    for (final addr in localAddress) {
      final net = wireGuardCidrNetwork(addr);
      if (net != null) out.add(net);
    }
    for (final cidr in extraCidrs) {
      final net = wireGuardCidrNetwork(cidr);
      if (net != null) out.add(net);
    }
    final seen = <String>{};
    return out.where((c) => seen.add(c)).toList(growable: false);
  }

  WireGuardIntranet copyWith({
    bool? enabled,
    String? server,
    int? serverPort,
    String? privateKey,
    String? peerPublicKey,
    List<String>? localAddress,
    String? preSharedKey,
    bool clearPreSharedKey = false,
    int? mtu,
    bool clearMtu = false,
    int? persistentKeepalive,
    List<String>? extraCidrs,
  }) {
    return WireGuardIntranet(
      enabled: enabled ?? this.enabled,
      server: server ?? this.server,
      serverPort: serverPort ?? this.serverPort,
      privateKey: privateKey ?? this.privateKey,
      peerPublicKey: peerPublicKey ?? this.peerPublicKey,
      localAddress: localAddress ?? this.localAddress,
      preSharedKey: clearPreSharedKey ? null : (preSharedKey ?? this.preSharedKey),
      mtu: clearMtu ? null : (mtu ?? this.mtu),
      persistentKeepalive: persistentKeepalive ?? this.persistentKeepalive,
      extraCidrs: extraCidrs ?? this.extraCidrs,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'server': server,
        'serverPort': serverPort,
        'privateKey': privateKey,
        'peerPublicKey': peerPublicKey,
        'localAddress': localAddress,
        if (preSharedKey != null) 'preSharedKey': preSharedKey,
        if (mtu != null) 'mtu': mtu,
        'persistentKeepalive': persistentKeepalive,
        'extraCidrs': extraCidrs,
      };

  factory WireGuardIntranet.fromJson(Map<String, dynamic> json) {
    List<String> parseList(dynamic value) {
      if (value is List) {
        return value
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }

    int parseInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim()) ?? fallback;
      return fallback;
    }

    final psk = json['preSharedKey']?.toString().trim();
    return WireGuardIntranet(
      enabled: json['enabled'] == true,
      server: json['server']?.toString().trim() ?? '',
      serverPort: parseInt(json['serverPort'], 0),
      privateKey: json['privateKey']?.toString().trim() ?? '',
      peerPublicKey: json['peerPublicKey']?.toString().trim() ?? '',
      localAddress: parseList(json['localAddress']),
      preSharedKey: (psk == null || psk.isEmpty) ? null : psk,
      mtu: json['mtu'] == null ? null : parseInt(json['mtu'], 0),
      persistentKeepalive: parseInt(json['persistentKeepalive'], 25),
      extraCidrs: parseList(json['extraCidrs']),
    );
  }
}

/// Normalizes an IPv4/IPv6 CIDR (or bare address) to its network/prefix form,
/// e.g. `10.8.0.2/24` -> `10.8.0.0/24`. Returns null for unparseable input.
/// IPv6 is passed through with its prefix (host-bit zeroing is left to the
/// kernel/sing-box, which match by prefix anyway).
String? wireGuardCidrNetwork(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final slash = value.indexOf('/');
  final host = slash >= 0 ? value.substring(0, slash) : value;
  final prefixPart = slash >= 0 ? value.substring(slash + 1) : null;
  if (host.contains(':')) {
    // IPv6 — keep as-is with a default /128 when no prefix given.
    return slash >= 0 ? value : '$value/128';
  }
  final octets = host.split('.');
  if (octets.length != 4) return null;
  final bytes = <int>[];
  for (final o in octets) {
    final n = int.tryParse(o);
    if (n == null || n < 0 || n > 255) return null;
    bytes.add(n);
  }
  final prefix = prefixPart == null ? 32 : int.tryParse(prefixPart);
  if (prefix == null || prefix < 0 || prefix > 32) return null;
  var bits = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  bits &= mask;
  final net =
      '${(bits >> 24) & 0xFF}.${(bits >> 16) & 0xFF}.${(bits >> 8) & 0xFF}.${bits & 0xFF}';
  return '$net/$prefix';
}

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
    this.customOutbounds = const [],
    this.customRules = const [],
    this.wireGuardIntranet = WireGuardIntranet.defaults,
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

  /// User-defined extra sing-box outbounds (each a raw outbound JSON map that
  /// must contain at least `tag` and `type`). These are merged into the
  /// generated sing-box config so custom routing rules can target them.
  final List<Map<String, dynamic>> customOutbounds;

  /// User-defined routing rules that can target any outbound tag (built-in
  /// `direct`/`proxy` or a custom outbound tag).
  final List<CustomRoutingRule> customRules;

  /// Independent intranet WireGuard overlay (separately switched, coexists with
  /// the proxy nodes). See [WireGuardIntranet].
  final WireGuardIntranet wireGuardIntranet;

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
          customProxyCidrs.length +
          customRules.length;
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
    List<Map<String, dynamic>>? customOutbounds,
    List<CustomRoutingRule>? customRules,
    WireGuardIntranet? wireGuardIntranet,
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
      customOutbounds: customOutbounds ?? this.customOutbounds,
      customRules: customRules ?? this.customRules,
      wireGuardIntranet: wireGuardIntranet ?? this.wireGuardIntranet,
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
      'customOutbounds': customOutbounds,
      'customRules': customRules.map((rule) => rule.toJson()).toList(),
      'wireGuardIntranet': wireGuardIntranet.toJson(),
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

    List<Map<String, dynamic>> parseOutbounds(dynamic value) {
      if (value is List) {
        return value
            .whereType<Map>()
            .map((item) =>
                Map<String, dynamic>.from(item))
            .where((item) =>
                item['tag']?.toString().trim().isNotEmpty == true &&
                item['type']?.toString().trim().isNotEmpty == true)
            .toList(growable: false);
      }
      return const [];
    }

    List<CustomRoutingRule> parseRules(dynamic value) {
      if (value is List) {
        return value
            .whereType<Map>()
            .map((item) => CustomRoutingRule.fromJson(
                Map<String, dynamic>.from(item)))
            .where((rule) => rule.value.isNotEmpty && rule.outbound.isNotEmpty)
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
      customOutbounds: parseOutbounds(json['customOutbounds']),
      customRules: parseRules(json['customRules']),
      wireGuardIntranet: json['wireGuardIntranet'] is Map
          ? WireGuardIntranet.fromJson(
              Map<String, dynamic>.from(json['wireGuardIntranet'] as Map))
          : WireGuardIntranet.defaults,
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

/// Tags reserved by the generated sing-box config; user outbounds must not
/// reuse them.
const reservedOutboundTags = {
  'direct',
  'block',
  'dns-out',
  'select',
  'auto',
};

String? validateVpnRoutingOutboundTag(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return 'Outbound tag cannot be empty';
  }
  if (normalized.contains(' ')) {
    return 'Outbound tag cannot contain spaces';
  }
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(normalized)) {
    return 'Invalid outbound tag: $value';
  }
  if (reservedOutboundTags.contains(normalized.toLowerCase())) {
    return 'Reserved tag, choose another: $value';
  }
  return null;
}

/// Builds an outbound-shaped WireGuard map from form fields. This stays the
/// familiar flat shape the UI collects and is stored verbatim in
/// [VpnRoutingSettings.customOutbounds]; the profile normalizer converts it
/// into a sing-box 1.12 WireGuard `endpoint` (see _buildWireguardEndpoint) so
/// routing rules can target [tag] while keepalive lives inside the peer.
Map<String, dynamic> buildWireguardOutbound({
  required String tag,
  required String server,
  required int serverPort,
  required String privateKey,
  required String peerPublicKey,
  required List<String> localAddress,
  String? preSharedKey,
  int? mtu,
}) {
  final outbound = <String, dynamic>{
    'type': 'wireguard',
    'tag': tag.trim(),
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
    outbound['pre_shared_key'] = psk;
  }
  if (mtu != null && mtu > 0) {
    outbound['mtu'] = mtu;
  }
  // Note: the bundled sing-box (v1.11) legacy WireGuard outbound has no
  // `persistent_keepalive_interval` field (it only exists on the 1.12+ endpoint
  // format). Emitting it makes sing-box reject the entire config, so it is
  // intentionally not set here; the normalizer also strips it defensively.
  return outbound;
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

  WireGuardIntranet get wireGuardIntranet =>
      _vpnRoutingSettings.wireGuardIntranet;

  /// Replace the whole intranet-WireGuard config (server, keys, CIDRs, …).
  Future<void> setWireGuardIntranet(WireGuardIntranet wg) async {
    await updateVpnRoutingSettings(
        _vpnRoutingSettings.copyWith(wireGuardIntranet: wg));
  }

  /// Independent on/off switch for the intranet WireGuard overlay, controlled
  /// separately from the proxy node selection.
  Future<void> setWireGuardIntranetEnabled(bool enabled) async {
    await updateVpnRoutingSettings(_vpnRoutingSettings.copyWith(
        wireGuardIntranet:
            _vpnRoutingSettings.wireGuardIntranet.copyWith(enabled: enabled)));
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
