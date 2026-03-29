import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

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
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    _directPrivateNetworks = settings.directPrivateNetworks;
    _directCnDomains = settings.directCnDomains;
    _directCnIpRanges = settings.directCnIpRanges;
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
      title: const Text('分流规则'),
      content: SizedBox(
        width: 560.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '默认内置规则参考常见规则模式：局域网直连、国内域名直连、国内 IP 直连。全局模式下仅保留局域网和自定义规则。',
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
                title: const Text('局域网 / 私网直连'),
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
                title: const Text('国内域名直连'),
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
                title: const Text('国内 IP 直连'),
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                context,
                controller: _directDomainsController,
                label: '自定义直连域名 / 后缀',
                hint: '每行一个，例如:\nexample.cn\ncorp.local',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                context,
                controller: _proxyDomainsController,
                label: '自定义代理域名 / 后缀',
                hint: '每行一个，例如:\nnetflix.com\nopenai.com',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                context,
                controller: _directCidrsController,
                label: '自定义直连 CIDR',
                hint: '每行一个，例如:\n10.10.0.0/16',
              ),
              SizedBox(height: 12.h),
              _buildTextField(
                context,
                controller: _proxyCidrsController,
                label: '自定义代理 CIDR',
                hint: '每行一个，例如:\n203.0.113.0/24',
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
          child: const Text('关闭'),
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
          child: const Text('恢复默认'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildTextField(
    BuildContext context, {
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

  Future<void> _save() async {
    final directDomains = _lines(_directDomainsController.text);
    final proxyDomains = _lines(_proxyDomainsController.text);
    final directCidrs = _lines(_directCidrsController.text);
    final proxyCidrs = _lines(_proxyCidrsController.text);

    final validationError = _validateEntries(
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

  String? _validateEntries({
    required List<String> directDomains,
    required List<String> proxyDomains,
    required List<String> directCidrs,
    required List<String> proxyCidrs,
  }) {
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
