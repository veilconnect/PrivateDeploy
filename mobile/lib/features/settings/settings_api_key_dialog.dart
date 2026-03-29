import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_provider.dart';

String maskedSettingsApiKey(String? apiKey) {
  final trimmed = apiKey?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Not set';
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
    return AlertDialog(
      title: const Text('API Key'),
      content: SizedBox(
        width: 520.w,
        child: TextField(
          controller: _controller,
          obscureText: true,
          enabled: !_saving,
          decoration: InputDecoration(
            hintText: 'Paste your Vultr API key',
            labelText: 'API Key',
            errorText: _dialogError,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _verifyAndSave,
          child: _saving
              ? const Text('Verifying...')
              : const Text('Verify & Save'),
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
          const SnackBar(
            content: Text('API key saved and verified'),
            backgroundColor: Colors.green,
          ),
        );
      }
      return;
    }

    setState(() {
      _saving = false;
      _dialogError = widget.cloud.error ?? 'Failed to save API key';
    });
  }
}
