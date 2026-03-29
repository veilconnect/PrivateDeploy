import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/storage/storage_service.dart';

enum VpnRoutingMode {
  split,
  global,
}

@immutable
class VpnRoutingSettings {
  const VpnRoutingSettings({
    this.mode = VpnRoutingMode.split,
    this.directPrivateNetworks = true,
    this.directCnDomains = true,
    this.directCnIpRanges = true,
    this.customDirectDomains = const [],
    this.customProxyDomains = const [],
    this.customDirectCidrs = const [],
    this.customProxyCidrs = const [],
  });

  final VpnRoutingMode mode;
  final bool directPrivateNetworks;
  final bool directCnDomains;
  final bool directCnIpRanges;
  final List<String> customDirectDomains;
  final List<String> customProxyDomains;
  final List<String> customDirectCidrs;
  final List<String> customProxyCidrs;

  static const defaults = VpnRoutingSettings();

  bool get isSplitMode => mode == VpnRoutingMode.split;

  String get modeLabel => isSplitMode ? '分流' : '全局';

  String get summary {
    if (mode == VpnRoutingMode.global) {
      final customCount = customDirectDomains.length +
          customProxyDomains.length +
          customDirectCidrs.length +
          customProxyCidrs.length;
      if (customCount == 0) {
        return '默认全部走 VPN，仅保留局域网直连';
      }
      return '默认全部走 VPN，保留局域网直连，自定义规则 $customCount 条';
    }

    final enabledBuiltins = <String>[
      if (directPrivateNetworks) '局域网直连',
      if (directCnDomains) '国内域名直连',
      if (directCnIpRanges) '国内 IP 直连',
    ];
    final customCount = customDirectDomains.length +
        customProxyDomains.length +
        customDirectCidrs.length +
        customProxyCidrs.length;
    final builtinText =
        enabledBuiltins.isEmpty ? '未启用内置规则' : enabledBuiltins.join('、');
    if (customCount == 0) {
      return builtinText;
    }
    return '$builtinText，自定义规则 $customCount 条';
  }

  VpnRoutingSettings copyWith({
    VpnRoutingMode? mode,
    bool? directPrivateNetworks,
    bool? directCnDomains,
    bool? directCnIpRanges,
    List<String>? customDirectDomains,
    List<String>? customProxyDomains,
    List<String>? customDirectCidrs,
    List<String>? customProxyCidrs,
  }) {
    return VpnRoutingSettings(
      mode: mode ?? this.mode,
      directPrivateNetworks:
          directPrivateNetworks ?? this.directPrivateNetworks,
      directCnDomains: directCnDomains ?? this.directCnDomains,
      directCnIpRanges: directCnIpRanges ?? this.directCnIpRanges,
      customDirectDomains: customDirectDomains ?? this.customDirectDomains,
      customProxyDomains: customProxyDomains ?? this.customProxyDomains,
      customDirectCidrs: customDirectCidrs ?? this.customDirectCidrs,
      customProxyCidrs: customProxyCidrs ?? this.customProxyCidrs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'directPrivateNetworks': directPrivateNetworks,
      'directCnDomains': directCnDomains,
      'directCnIpRanges': directCnIpRanges,
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
      directPrivateNetworks: json['directPrivateNetworks'] != false,
      directCnDomains: json['directCnDomains'] != false,
      directCnIpRanges: json['directCnIpRanges'] != false,
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
