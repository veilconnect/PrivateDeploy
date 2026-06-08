import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../../services/vpn_native_service.dart';
import 'app_settings_provider.dart';

Future<void> showSettingsRoutingRulesDialog({
  required BuildContext context,
  required VpnRoutingSettings settings,
  required Future<void> Function(VpnRoutingSettings settings) onSave,
  required Future<void> Function() onReset,
}) async {
  await showDialog(
    context: context,
    builder: (_) => _SettingsRoutingRulesDialog(
      initialSettings: settings,
      onSave: onSave,
      onReset: onReset,
    ),
  );
}

class _SettingsRoutingRulesDialog extends StatefulWidget {
  const _SettingsRoutingRulesDialog({
    required this.initialSettings,
    required this.onSave,
    required this.onReset,
  });

  final VpnRoutingSettings initialSettings;
  final Future<void> Function(VpnRoutingSettings settings) onSave;
  final Future<void> Function() onReset;

  @override
  State<_SettingsRoutingRulesDialog> createState() =>
      _SettingsRoutingRulesDialogState();
}

class _SettingsRoutingRulesDialogState
    extends State<_SettingsRoutingRulesDialog> {
  late VpnDnsMode _dnsMode;
  late bool _directPrivateNetworks;
  late bool _directCnDomains;
  late bool _directCnIpRanges;
  late final TextEditingController _directDomainsController;
  late final TextEditingController _proxyDomainsController;
  late final TextEditingController _directCidrsController;
  late final TextEditingController _proxyCidrsController;
  late final TextEditingController _customOutboundsController;
  late final TextEditingController _customRulesController;
  late List<String> _directPackages;
  late List<String> _proxyPackages;
  List<VpnInstalledApp> _installedApps = const [];
  bool _loadingApps = false;
  bool _saving = false;
  String? _appsError;
  String? _errorText;

  bool get _supportsPackageRouting =>
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    _dnsMode = settings.dnsMode;
    _directPrivateNetworks = settings.directPrivateNetworks;
    _directCnDomains = settings.directCnDomains;
    _directCnIpRanges = settings.directCnIpRanges;
    _directPackages = List<String>.from(settings.customDirectPackages);
    _proxyPackages = List<String>.from(settings.customProxyPackages);
    _directDomainsController = TextEditingController(
      text: settings.customDirectDomains.join('\n'),
    );
    _proxyDomainsController = TextEditingController(
      text: settings.customProxyDomains.join('\n'),
    );
    _directCidrsController = TextEditingController(
      text: settings.customDirectCidrs.join('\n'),
    );
    _proxyCidrsController = TextEditingController(
      text: settings.customProxyCidrs.join('\n'),
    );
    _customOutboundsController = TextEditingController(
      text: settings.customOutbounds.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ')
              .convert(settings.customOutbounds),
    );
    _customRulesController = TextEditingController(
      text: settings.customRules
          .map((rule) =>
              '${rule.matcher == CustomRuleMatcher.ipCidr ? 'ip_cidr' : 'domain_suffix'} ${rule.value} ${rule.outbound}')
          .join('\n'),
    );
    if (_supportsPackageRouting) {
      _loadInstalledApps();
    }
  }

  @override
  void dispose() {
    _directDomainsController.dispose();
    _proxyDomainsController.dispose();
    _directCidrsController.dispose();
    _proxyCidrsController.dispose();
    _customOutboundsController.dispose();
    _customRulesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.editRoutingRules),
      content: SizedBox(
        width: 560.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.routingRulesHelp,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: 12.h),
              Text(
                l10n.dnsMode,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              SizedBox(height: 8.h),
              DropdownButtonFormField<VpnDnsMode>(
                initialValue: _dnsMode,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: VpnDnsMode.chinaOptimized,
                    child: Text(l10n.cnOptimizedDns),
                  ),
                  DropdownMenuItem(
                    value: VpnDnsMode.strictProxy,
                    child: Text(l10n.strictProxyDns),
                  ),
                  DropdownMenuItem(
                    value: VpnDnsMode.systemResolver,
                    child: Text(l10n.systemDns),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _dnsMode = value;
                        });
                      },
              ),
              SizedBox(height: 12.h),
              CheckboxListTile(
                value: _directPrivateNetworks,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() {
                          _directPrivateNetworks = value ?? true;
                        });
                      },
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.lanDirectRule),
              ),
              CheckboxListTile(
                value: _directCnDomains,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() {
                          _directCnDomains = value ?? true;
                        });
                      },
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.cnDomainsDirectRule),
              ),
              CheckboxListTile(
                value: _directCnIpRanges,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() {
                          _directCnIpRanges = value ?? true;
                        });
                      },
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.cnIpsDirectRule),
              ),
              SizedBox(height: 12.h),
              _buildAppRuleTile(
                context,
                title: l10n.directApps,
                subtitle: _supportsPackageRouting
                    ? _packageSummary(_directPackages, l10n)
                    : l10n.perAppAndroidOnly,
                icon: Icons.phone_android_outlined,
                enabled: _supportsPackageRouting && !_saving,
                onTap: () => _openPackagePicker(
                  title: l10n.pickDirectApps,
                  currentPackages: _directPackages,
                  oppositePackages: _proxyPackages,
                  onSelected: (selected) {
                    setState(() {
                      _directPackages = selected;
                    });
                  },
                ),
              ),
              _buildAppRuleTile(
                context,
                title: l10n.proxiedApps,
                subtitle: _supportsPackageRouting
                    ? _packageSummary(_proxyPackages, l10n)
                    : l10n.perAppAndroidOnly,
                icon: Icons.rocket_launch_outlined,
                enabled: _supportsPackageRouting && !_saving,
                onTap: () => _openPackagePicker(
                  title: l10n.pickProxiedApps,
                  currentPackages: _proxyPackages,
                  oppositePackages: _directPackages,
                  onSelected: (selected) {
                    setState(() {
                      _proxyPackages = selected;
                    });
                  },
                ),
              ),
              if (_appsError != null) ...[
                SizedBox(height: 8.h),
                Text(
                  _appsError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12.sp,
                  ),
                ),
              ],
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _directDomainsController,
                label: l10n.customDirectDomains,
                hint: l10n.customDirectDomainsHint,
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _proxyDomainsController,
                label: l10n.customProxiedDomains,
                hint: l10n.customProxiedDomainsHint,
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _directCidrsController,
                label: l10n.customDirectCidrs,
                hint: l10n.customDirectCidrsHint,
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _proxyCidrsController,
                label: l10n.customProxiedCidrs,
                hint: l10n.customProxiedCidrsHint,
              ),
              SizedBox(height: 16.h),
              Divider(height: 1.h),
              SizedBox(height: 12.h),
              Text(
                '高级 · 自定义出站与规则',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              SizedBox(height: 4.h),
              Text(
                '可定义额外出站（如 WireGuard 隧道到内网），并用自定义规则把指定流量指向它。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _customOutboundsController,
                label: '自定义出站 (sing-box 出站 JSON)',
                hint:
                    '粘贴单个 JSON 对象或数组，每个须含 tag 与 type。例（WireGuard）：\n{"type":"wireguard","tag":"home-wg","server":"1.2.3.4","server_port":51820,"local_address":["10.0.0.20/32"],"private_key":"<私钥>","peer_public_key":"<对端公钥>"}',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _customRulesController,
                label: '自定义规则（每行一条）',
                hint: '格式：<domain_suffix|ip_cidr> <值> <出站tag>\n例：ip_cidr 10.0.0.0/24 home-wg',
              ),
              if (_errorText != null) ...[
                SizedBox(height: 12.h),
                Text(
                  _errorText!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
        OutlinedButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                  });
                  await widget.onReset();
                  if (!context.mounted) {
                    return;
                  }
                  Navigator.pop(context);
                },
          child: Text(l10n.resetToDefaults),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.save),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      enabled: !_saving,
      minLines: 3,
      maxLines: 5,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildAppRuleTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: _loadingApps
          ? SizedBox(
              width: 18.w,
              height: 18.w,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      enabled: enabled,
      onTap: enabled ? onTap : null,
    );
  }

  Future<void> _loadInstalledApps() async {
    setState(() {
      _loadingApps = true;
      _appsError = null;
    });

    final apps = await VpnNativeService.instance.getInstalledApps();
    if (!mounted) {
      return;
    }

    setState(() {
      _installedApps = apps;
      _loadingApps = false;
      if (apps.isEmpty && mounted) {
        _appsError = AppLocalizations.of(context)!.appListError;
      }
    });
  }

  Future<void> _openPackagePicker({
    required String title,
    required List<String> currentPackages,
    required List<String> oppositePackages,
    required ValueChanged<List<String>> onSelected,
  }) async {
    if (_loadingApps) {
      return;
    }
    if (_installedApps.isEmpty) {
      await _loadInstalledApps();
      if (!mounted || _installedApps.isEmpty) {
        return;
      }
    }

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) => _RoutingPackagePickerDialog(
        title: title,
        installedApps: _installedApps,
        initialSelection: currentPackages,
        disabledPackages: oppositePackages.toSet(),
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    onSelected(selected);
  }

  Future<void> _save() async {
    final directDomains = _lines(_directDomainsController.text);
    final proxyDomains = _lines(_proxyDomainsController.text);
    final directCidrs = _lines(_directCidrsController.text);
    final proxyCidrs = _lines(_proxyCidrsController.text);

    final validationError = _validateEntries(
      directPackages: _directPackages,
      proxyPackages: _proxyPackages,
      directDomains: directDomains,
      proxyDomains: proxyDomains,
      directCidrs: directCidrs,
      proxyCidrs: proxyCidrs,
    );
    if (validationError != null) {
      setState(() {
        _errorText = validationError;
      });
      return;
    }

    final customOutboundsResult =
        _parseCustomOutbounds(_customOutboundsController.text);
    if (customOutboundsResult.error != null) {
      setState(() {
        _errorText = customOutboundsResult.error;
      });
      return;
    }
    final customRulesResult = _parseCustomRules(_customRulesController.text);
    if (customRulesResult.error != null) {
      setState(() {
        _errorText = customRulesResult.error;
      });
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });

    final settings = widget.initialSettings.copyWith(
      dnsMode: _dnsMode,
      directPrivateNetworks: _directPrivateNetworks,
      directCnDomains: _directCnDomains,
      directCnIpRanges: _directCnIpRanges,
      customDirectPackages: _directPackages,
      customProxyPackages: _proxyPackages,
      customDirectDomains: directDomains,
      customProxyDomains: proxyDomains,
      customDirectCidrs: directCidrs,
      customProxyCidrs: proxyCidrs,
      customOutbounds: customOutboundsResult.value,
      customRules: customRulesResult.value,
    );

    await widget.onSave(settings);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);
  }

  ({List<Map<String, dynamic>> value, String? error}) _parseCustomOutbounds(
      String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return (value: const <Map<String, dynamic>>[], error: null);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (error) {
      return (
        value: const <Map<String, dynamic>>[],
        error: '自定义出站 JSON 解析失败: $error',
      );
    }
    final list = decoded is List ? decoded : [decoded];
    final result = <Map<String, dynamic>>[];
    final tags = <String>{};
    for (final item in list) {
      if (item is! Map) {
        return (
          value: const <Map<String, dynamic>>[],
          error: '自定义出站必须是 JSON 对象',
        );
      }
      final map = Map<String, dynamic>.from(item);
      final tag = map['tag']?.toString().trim() ?? '';
      final type = map['type']?.toString().trim() ?? '';
      if (tag.isEmpty || type.isEmpty) {
        return (
          value: const <Map<String, dynamic>>[],
          error: '每个自定义出站必须含非空的 tag 和 type',
        );
      }
      final tagError = validateVpnRoutingOutboundTag(tag);
      if (tagError != null) {
        return (value: const <Map<String, dynamic>>[], error: tagError);
      }
      if (!tags.add(tag)) {
        return (
          value: const <Map<String, dynamic>>[],
          error: '出站 tag 重复: $tag',
        );
      }
      result.add(map);
    }
    return (value: result, error: null);
  }

  ({List<CustomRoutingRule> value, String? error}) _parseCustomRules(
      String text) {
    final result = <CustomRoutingRule>[];
    for (final line in _lines(text)) {
      final parts =
          line.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
      if (parts.length != 3) {
        return (
          value: const <CustomRoutingRule>[],
          error: '规则格式错误（应为 “matcher 值 出站tag”）: $line',
        );
      }
      final matcher = switch (parts[0].toLowerCase()) {
        'domain_suffix' => CustomRuleMatcher.domainSuffix,
        'ip_cidr' => CustomRuleMatcher.ipCidr,
        _ => null,
      };
      if (matcher == null) {
        return (
          value: const <CustomRoutingRule>[],
          error: 'matcher 仅支持 domain_suffix / ip_cidr: ${parts[0]}',
        );
      }
      final value = parts[1];
      final valueError = matcher == CustomRuleMatcher.ipCidr
          ? validateVpnRoutingCidr(value)
          : validateVpnRoutingDomain(value);
      if (valueError != null) {
        return (value: const <CustomRoutingRule>[], error: valueError);
      }
      result.add(CustomRoutingRule(
        matcher: matcher,
        value: value,
        outbound: parts[2],
      ));
    }
    return (value: result, error: null);
  }

  List<String> _lines(String raw) {
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _packageSummary(List<String> packages, AppLocalizations l10n) {
    if (packages.isEmpty) {
      return l10n.noAppSelected;
    }
    final labels = packages
        .map(_labelForPackage)
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
    if (labels.length <= 2) {
      return labels.join(', ');
    }
    return l10n.appCountSelected(labels.first, labels.length - 1);
  }

  String _labelForPackage(String packageName) {
    final app = _installedApps
        .where((item) => item.packageName == packageName)
        .firstOrNull;
    return app?.label ?? packageName;
  }

  String? _validateEntries({
    required List<String> directPackages,
    required List<String> proxyPackages,
    required List<String> directDomains,
    required List<String> proxyDomains,
    required List<String> directCidrs,
    required List<String> proxyCidrs,
  }) {
    for (final packageName in [...directPackages, ...proxyPackages]) {
      final error = validateVpnRoutingPackageName(packageName);
      if (error != null) {
        return error;
      }
    }

    final packageOverlap = directPackages.toSet().intersection(
          proxyPackages.toSet(),
        );
    if (packageOverlap.isNotEmpty) {
      return AppLocalizations.of(context)!.appBothDirectProxied;
    }

    for (final domain in [...directDomains, ...proxyDomains]) {
      final error = validateVpnRoutingDomain(domain);
      if (error != null) {
        return error;
      }
    }

    for (final cidr in [...directCidrs, ...proxyCidrs]) {
      final error = validateVpnRoutingCidr(cidr);
      if (error != null) {
        return error;
      }
    }
    return null;
  }
}

class _RoutingPackagePickerDialog extends StatefulWidget {
  const _RoutingPackagePickerDialog({
    required this.title,
    required this.installedApps,
    required this.initialSelection,
    required this.disabledPackages,
  });

  final String title;
  final List<VpnInstalledApp> installedApps;
  final List<String> initialSelection;
  final Set<String> disabledPackages;

  @override
  State<_RoutingPackagePickerDialog> createState() =>
      _RoutingPackagePickerDialogState();
}

class _RoutingPackagePickerDialogState
    extends State<_RoutingPackagePickerDialog> {
  late final TextEditingController _searchController;
  late Set<String> _selectedPackages;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selectedPackages = widget.initialSelection.toSet();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredApps = widget.installedApps.where((app) {
      if (_query.isEmpty) {
        return true;
      }
      final q = _query.toLowerCase();
      return app.label.toLowerCase().contains(q) ||
          app.packageName.toLowerCase().contains(q);
    }).toList(growable: false);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.searchApp,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) {
                setState(() {
                  _query = value.trim();
                });
              },
            ),
            SizedBox(height: 12.h),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: filteredApps.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final app = filteredApps[index];
                  final disabled =
                      widget.disabledPackages.contains(app.packageName);
                  final selected = _selectedPackages.contains(app.packageName);
                  return CheckboxListTile(
                    value: selected,
                    contentPadding: EdgeInsets.zero,
                    title: Text(app.label),
                    subtitle: Text(app.packageName),
                    secondary: disabled
                        ? const Icon(Icons.lock_outline, size: 18)
                        : null,
                    onChanged: disabled
                        ? null
                        : (value) {
                            setState(() {
                              if (value == true) {
                                _selectedPackages.add(app.packageName);
                              } else {
                                _selectedPackages.remove(app.packageName);
                              }
                            });
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context)!.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _selectedPackages.toList(growable: false)..sort(),
          ),
          child: Text(AppLocalizations.of(context)!.ok),
        ),
      ],
    );
  }
}
