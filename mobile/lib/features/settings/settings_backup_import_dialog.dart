import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_provider.dart';

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
