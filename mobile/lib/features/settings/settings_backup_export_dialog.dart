import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_backup.dart';
import '../cloud/cloud_provider.dart';
import 'settings_backup_preview_card.dart';

Future<void> showSettingsBackupExportDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final payload = await cloud.exportBackupJson();
  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupExportDialog(payload: payload),
  );
}

class _SettingsBackupExportDialog extends StatefulWidget {
  const _SettingsBackupExportDialog({required this.payload});

  final String payload;

  @override
  State<_SettingsBackupExportDialog> createState() =>
      _SettingsBackupExportDialogState();
}

class _SettingsBackupExportDialogState
    extends State<_SettingsBackupExportDialog> {
  late final CloudBackupPreview _preview;
  bool _revealed = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _preview = inspectCloudBackupJson(
      widget.payload,
      expectedProvider: vultrCloudBackupProvider,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud Backup Ready'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _revealed
                  ? 'Sensitive backup JSON is visible below. Store it safely because it includes your Vultr API key and node credentials.'
                  : _copied
                      ? 'Sensitive backup copied to your clipboard. Clipboard contents may be accessible to other apps until you replace them.'
                      : 'Review the backup summary below before copying. The backup includes sensitive data such as your Vultr API key and node credentials.',
            ),
            SizedBox(height: 12.h),
            SettingsBackupPreviewCard(preview: _preview),
            if (_revealed) ...[
              SizedBox(height: 12.h),
              Container(
                width: double.infinity,
                constraints: BoxConstraints(maxHeight: 280.h),
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(widget.payload),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: _copySensitiveBackup,
          child: Text(_copied ? 'Copy Again' : 'Copy Sensitive Backup'),
        ),
        FilledButton(
          onPressed: _toggleSensitiveJson,
          child: Text(_revealed ? 'Hide JSON' : 'Reveal JSON'),
        ),
      ],
    );
  }

  Future<void> _copySensitiveBackup() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Copy Sensitive Backup?'),
            content: const Text(
              'This will place the full backup JSON on the system clipboard, including the saved API key and node credentials.',
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Copy'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: widget.payload));
    if (!mounted) {
      return;
    }

    setState(() {
      _copied = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sensitive backup copied to clipboard')),
    );
  }

  Future<void> _toggleSensitiveJson() async {
    if (_revealed) {
      setState(() {
        _revealed = false;
      });
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Reveal Sensitive Backup?'),
            content: const Text(
              'This will display the full backup JSON on screen, including the saved API key and node credentials.',
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reveal'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) {
      return;
    }

    setState(() {
      _revealed = true;
    });
  }
}
