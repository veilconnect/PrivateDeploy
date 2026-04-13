import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';

String maskedSettingsApiKey(String? apiKey, {String notSetLabel = 'Not set'}) {
  final trimmed = apiKey?.trim() ?? '';
  if (trimmed.isEmpty) {
    return notSetLabel;
  }
  final visibleLength = trimmed.length < 8 ? trimmed.length : 8;
  return '${trimmed.substring(0, visibleLength)}...';
}

Future<void> showSettingsApiKeyDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  await showDialog(
    context: context,
    builder: (_) => _SettingsApiKeyDialog(rootContext: context, cloud: cloud),
  );
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
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.cloud.apiKey ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.apiKey),
      content: SizedBox(
        width: 520.w,
        child: TextField(
          controller: _controller,
          obscureText: true,
          enabled: !_saving,
          decoration: InputDecoration(
            hintText: l10n.pasteVultrApiKey,
            labelText: l10n.apiKey,
            errorText: _dialogError,
          ),
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
      await widget.cloud.loadInstances(notify: false);
      if (mounted) {
        Navigator.pop(context);
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
