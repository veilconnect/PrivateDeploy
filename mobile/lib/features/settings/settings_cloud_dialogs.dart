import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<void> showSettingsBackupExportDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final payload = await cloud.exportBackupJson();
  await Clipboard.setData(ClipboardData(text: payload));

  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupExportDialog(payload: payload),
  );
}

Future<void> showSettingsBackupImportDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final clipboard = await Clipboard.getData('text/plain');

  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupImportDialog(
      rootContext: context,
      cloud: cloud,
      initialValue: clipboard?.text ?? '',
    ),
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

class _SettingsBackupExportDialog extends StatelessWidget {
  const _SettingsBackupExportDialog({required this.payload});

  final String payload;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud Backup Copied'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This JSON has already been copied to your clipboard. Store it safely because it includes your Vultr API key.',
            ),
            SizedBox(height: 12.h),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12.w),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: SelectableText(payload),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: payload));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Backup copied again')),
              );
            }
          },
          child: const Text('Copy Again'),
        ),
      ],
    );
  }
}

class _SettingsBackupImportDialog extends StatefulWidget {
  const _SettingsBackupImportDialog({
    required this.rootContext,
    required this.cloud,
    required this.initialValue,
  });

  final BuildContext rootContext;
  final CloudProvider cloud;
  final String initialValue;

  @override
  State<_SettingsBackupImportDialog> createState() =>
      _SettingsBackupImportDialogState();
}

class _SettingsBackupImportDialogState
    extends State<_SettingsBackupImportDialog> {
  late final TextEditingController _controller;
  String? _dialogError;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore Cloud Backup'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a backup JSON exported from this app. If it includes an API key, the current key will be replaced.',
            ),
            SizedBox(height: 12.h),
            TextField(
              controller: _controller,
              minLines: 10,
              maxLines: 14,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'Paste cloud backup JSON here',
                errorText: _dialogError,
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _restoring ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: _restoring ? null : _pasteClipboard,
          child: const Text('Paste Clipboard'),
        ),
        FilledButton(
          onPressed: _restoring ? null : _restoreBackup,
          child: _restoring
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Restore'),
        ),
      ],
    );
  }

  Future<void> _pasteClipboard() async {
    final latest = await Clipboard.getData('text/plain');
    if (!mounted) {
      return;
    }
    setState(() {
      _controller.text = latest?.text ?? '';
      _dialogError = null;
    });
  }

  Future<void> _restoreBackup() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _dialogError = 'Backup JSON cannot be empty';
      });
      return;
    }

    setState(() {
      _restoring = true;
      _dialogError = null;
    });

    try {
      await widget.cloud.importBackupJson(raw);
      if (mounted) {
        Navigator.pop(context);
      }
      if (widget.rootContext.mounted) {
        ScaffoldMessenger.of(widget.rootContext).showSnackBar(
          const SnackBar(content: Text('Cloud backup restored')),
        );
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogError = e.toString().replaceFirst('Exception: ', '');
        _restoring = false;
      });
    }
  }
}
