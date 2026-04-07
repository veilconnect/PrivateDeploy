import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

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
  late bool _directPrivateNetworks;
  late bool _directCnDomains;
  late bool _directCnIpRanges;
  late final TextEditingController _directDomainsController;
  late final TextEditingController _proxyDomainsController;
  late final TextEditingController _directCidrsController;
  late final TextEditingController _proxyCidrsController;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Routing Rules'),
      content: SizedBox(
        width: 560.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Built-in defaults follow common split patterns: LAN direct, '
                'CN domains direct, CN IPs direct. Global mode only keeps LAN '
                'and custom rules.',
                style: Theme.of(context).textTheme.bodySmall,
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
                title: const Text('LAN / private networks direct'),
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
                title: const Text('CN domains direct'),
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
                title: const Text('CN IPs direct'),
              ),
              SizedBox(height: 12.h),
              _buildAppRuleTile(
                context,
                title: 'Direct apps',
                subtitle: _supportsPackageRouting
                    ? _packageSummary(_directPackages)
                    : 'Per-app routing is Android-only',
                icon: Icons.phone_android_outlined,
                enabled: _supportsPackageRouting && !_saving,
                onTap: () => _openPackagePicker(
                  title: 'Pick direct apps',
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
                title: 'Proxied apps',
                subtitle: _supportsPackageRouting
                    ? _packageSummary(_proxyPackages)
                    : 'Per-app routing is Android-only',
                icon: Icons.rocket_launch_outlined,
                enabled: _supportsPackageRouting && !_saving,
                onTap: () => _openPackagePicker(
                  title: 'Pick proxied apps',
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
                label: 'Custom direct domains / suffixes',
                hint: 'One per line, e.g.:\nexample.cn\ncorp.local',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _proxyDomainsController,
                label: 'Custom proxied domains / suffixes',
                hint: 'One per line, e.g.:\nnetflix.com\nopenai.com',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _directCidrsController,
                label: 'Custom direct CIDRs',
                hint: 'One per line, e.g.:\n10.10.0.0/16',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                controller: _proxyCidrsController,
                label: 'Custom proxied CIDRs',
                hint: 'One per line, e.g.:\n203.0.113.0/24',
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
          child: const Text('Close'),
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
          child: const Text('Reset to defaults'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
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
      if (apps.isEmpty) {
        _appsError =
            'Could not list apps; you can still save domain and CIDR rules.';
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

    setState(() {
      _saving = true;
      _errorText = null;
    });

    final settings = widget.initialSettings.copyWith(
      directPrivateNetworks: _directPrivateNetworks,
      directCnDomains: _directCnDomains,
      directCnIpRanges: _directCnIpRanges,
      customDirectPackages: _directPackages,
      customProxyPackages: _proxyPackages,
      customDirectDomains: directDomains,
      customProxyDomains: proxyDomains,
      customDirectCidrs: directCidrs,
      customProxyCidrs: proxyCidrs,
    );

    await widget.onSave(settings);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);
  }

  List<String> _lines(String raw) {
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _packageSummary(List<String> packages) {
    if (packages.isEmpty) {
      return '未选择 App';
    }
    final labels = packages
        .map(_labelForPackage)
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
    if (labels.length <= 2) {
      return labels.join('、');
    }
    return '${labels.take(2).join('、')} 等 ${labels.length} 个 App';
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
      return 'An app cannot be both direct and proxied';
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
              decoration: const InputDecoration(
                labelText: '搜索 App',
                prefixIcon: Icon(Icons.search),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _selectedPackages.toList(growable: false)..sort(),
          ),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
