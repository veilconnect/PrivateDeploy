import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';

String maskedSettingsApiKey(
  String? apiKey, {
  required String notSetLabel,
  required String Function(int length) configuredLabel,
}) {
  final trimmed = apiKey?.trim() ?? '';
  if (trimmed.isEmpty) {
    return notSetLabel;
  }
  return configuredLabel(trimmed.length);
}

Future<bool> showSettingsApiKeyDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _SettingsApiKeyDialog(rootContext: context, cloud: cloud),
  );
  return saved ?? false;
}

class _SettingsApiKeyDialog extends StatefulWidget {
  const _SettingsApiKeyDialog({
    required this.rootContext,
    required this.cloud,
  });

  final BuildContext rootContext;
  final CloudProvider cloud;

  @override
  State<_SettingsApiKeyDialog> createState() => _SettingsApiKeyDialogState();
}

class _SettingsApiKeyDialogState extends State<_SettingsApiKeyDialog> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _saving = false;
  bool _savedSuccessfully = false;
  String? _dialogError;
  CloudProviderId? _selectedProvider;
  late final CloudProviderId _originalProvider;

  @override
  void initState() {
    super.initState();
    _originalProvider = widget.cloud.providerId;
    _selectedProvider = widget.cloud.hasPersistedActiveProviderSelection ||
            widget.cloud.hasStoredApiKey
        ? _originalProvider
        : null;
    _apiKeyController = TextEditingController(text: widget.cloud.apiKey ?? '');
    _hostController = TextEditingController(
      text: widget.cloud.providerExtra['host'] ?? '',
    );
    _portController = TextEditingController(
      text: widget.cloud.providerExtra['port'] ?? '22',
    );
    _usernameController = TextEditingController(
      text: widget.cloud.providerExtra['username'] ?? 'root',
    );
    _passwordController = TextEditingController(
      text: widget.cloud.providerExtra['password'] ?? '',
    );
  }

  @override
  void dispose() {
    // If the user dismissed the dialog without saving (Cancel, system back,
    // or dismiss-by-tap), roll the active provider back to what it was when
    // the dialog opened. Switching the dropdown is a preview action, not a
    // commit — only "Verify & Save" persists the change.
    if (!_savedSuccessfully &&
        widget.cloud.providerId != _originalProvider) {
      unawaited(widget.cloud.setActiveProvider(_originalProvider));
    }
    _apiKeyController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onProviderChanged(CloudProviderId? next) async {
    if (next == null || next == _selectedProvider || _saving) {
      return;
    }
    // Switch the active provider so the text field can preview the per-
    // provider stored key. If the user cancels, dispose() rolls this back.
    await widget.cloud.setActiveProvider(next);
    if (!mounted) return;
    setState(() {
      _selectedProvider = next;
      _apiKeyController.text = widget.cloud.apiKey ?? '';
      _hostController.text = widget.cloud.providerExtra['host'] ?? '';
      _portController.text = widget.cloud.providerExtra['port'] ?? '22';
      _usernameController.text =
          widget.cloud.providerExtra['username'] ?? 'root';
      _passwordController.text = widget.cloud.providerExtra['password'] ?? '';
      _dialogError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isSsh = _selectedProvider == CloudProviderId.ssh;
    return AlertDialog(
      title: Text(l10n.cloudAccess),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<CloudProviderId>(
              initialValue: _selectedProvider,
              hint: Text(l10n.cloudProvider),
              decoration: InputDecoration(
                labelText: l10n.cloudProvider,
                border: const OutlineInputBorder(),
              ),
              items: CloudProviderId.values
                  .map(
                    (provider) => DropdownMenuItem(
                      value: provider,
                      child: Text(provider.displayName),
                    ),
                  )
                  .toList(),
              onChanged: _saving ? null : _onProviderChanged,
            ),
            SizedBox(height: 12.h),
            if (isSsh) ...[
              TextField(
                controller: _hostController,
                enabled: !_saving && _selectedProvider != null,
                decoration: InputDecoration(
                  hintText: '203.0.113.10',
                  labelText: l10n.sshHost,
                  errorText: _dialogError,
                ),
              ),
              SizedBox(height: 12.h),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      enabled: !_saving && _selectedProvider != null,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: '22',
                        labelText: l10n.port,
                      ),
                    ),
                  ),
                  SizedBox(width: 12.w),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _usernameController,
                      enabled: !_saving && _selectedProvider != null,
                      decoration: InputDecoration(
                        hintText: 'root',
                        labelText: l10n.username,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.h),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enabled: !_saving && _selectedProvider != null,
                decoration: InputDecoration(
                  labelText: l10n.sshPassword,
                ),
              ),
            ] else
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                enabled: !_saving && _selectedProvider != null,
                decoration: InputDecoration(
                  hintText: _selectedProvider == null
                      ? null
                      : l10n.pasteCloudProviderApiKey(
                          _selectedProvider!.displayName,
                        ),
                  labelText: l10n.apiKey,
                  errorText: _dialogError,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed:
              _saving || _selectedProvider == null ? null : _verifyAndSave,
          child: _saving
              ? Text(l10n.verifying)
              : Text(l10n.verifyAndSave),
        ),
      ],
    );
  }

  Future<void> _verifyAndSave() async {
    setState(() {
      _saving = true;
      _dialogError = null;
    });

    final success = _selectedProvider == CloudProviderId.ssh
        ? await widget.cloud.setSshAccessConfig(
            host: _hostController.text.trim(),
            port: _portController.text.trim(),
            username: _usernameController.text.trim(),
            password: _passwordController.text,
          )
        : await widget.cloud.setApiKey(_apiKeyController.text.trim());
    if (success) {
      // A transient-network save-first path can return success with a
      // warning still in widget.cloud.error — "saved, will verify when
      // network reaches the provider". Distinguish from a fully
      // verified save so the snackbar isn't misleading.
      final saveOnlyWarning = widget.cloud.error;
      await widget.cloud.loadInstances();
      if (!mounted) {
        return;
      }
      _savedSuccessfully = true;
      Navigator.pop(context, true);
      if (widget.rootContext.mounted) {
        final messenger = ScaffoldMessenger.of(widget.rootContext);
        if (saveOnlyWarning != null && saveOnlyWarning.isNotEmpty) {
          messenger.showSnackBar(SnackBar(
            content: Text(saveOnlyWarning),
            backgroundColor: const Color(0xFFCA8A04),
            duration: const Duration(seconds: 6),
          ));
        } else {
          messenger.showSnackBar(SnackBar(
            content: Text(
              AppLocalizations.of(widget.rootContext)!
                  .cloudAccessSavedAndVerified,
            ),
            backgroundColor: Colors.green,
          ));
        }
      }
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _dialogError =
          widget.cloud.error ??
          AppLocalizations.of(context)!.failedToSaveCloudAccess;
    });
  }
}
