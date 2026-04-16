import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';

String maskedSettingsApiKey(String? apiKey, {String notSetLabel = 'Not set'}) {
  final trimmed = apiKey?.trim() ?? '';
  if (trimmed.isEmpty) {
    return notSetLabel;
  }
  final visibleLength = trimmed.length < 8 ? trimmed.length : 8;
  return '${trimmed.substring(0, visibleLength)}...';
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
  late final TextEditingController _controller;
  bool _saving = false;
  bool _savedSuccessfully = false;
  String? _dialogError;
  late CloudProviderId _selectedProvider;
  late final CloudProviderId _originalProvider;

  @override
  void initState() {
    super.initState();
    _originalProvider = widget.cloud.providerId;
    _selectedProvider = _originalProvider;
    _controller = TextEditingController(text: widget.cloud.apiKey ?? '');
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
    _controller.dispose();
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
      _controller.text = widget.cloud.apiKey ?? '';
      _dialogError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.apiKey),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<CloudProviderId>(
              value: _selectedProvider,
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
            TextField(
              controller: _controller,
              obscureText: true,
              enabled: !_saving,
              decoration: InputDecoration(
                hintText: l10n.pasteCloudProviderApiKey(
                    _selectedProvider.displayName),
                labelText: l10n.apiKey,
                errorText: _dialogError,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _verifyAndSave,
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

    final success = await widget.cloud.setApiKey(_controller.text.trim());
    if (!mounted) {
      return;
    }

    if (success) {
      _savedSuccessfully = true;
      await widget.cloud.loadInstances(notify: false);
      if (mounted) {
        Navigator.pop(context, true);
      }
      if (widget.rootContext.mounted) {
        ScaffoldMessenger.of(widget.rootContext).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(widget.rootContext)!.apiKeySavedAndVerified),
            backgroundColor: Colors.green,
          ),
        );
      }
      return;
    }

    setState(() {
      _saving = false;
      _dialogError = widget.cloud.error ?? AppLocalizations.of(context)!.failedToSaveApiKey;
    });
  }
}
