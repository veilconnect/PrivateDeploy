import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.cloudBackupReady),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _revealed
                  ? l10n.backupSensitiveWarning
                  : _copied
                      ? l10n.backupClipboardWarning
                      : l10n.backupReviewWarning,
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
          child: Text(l10n.close),
        ),
        FilledButton.tonal(
          onPressed: _copySensitiveBackup,
          child: Text(_copied ? l10n.copyAgain : l10n.copySensitiveBackup),
        ),
        FilledButton(
          onPressed: _toggleSensitiveJson,
          child: Text(_revealed ? l10n.hideJson : l10n.revealJson),
        ),
      ],
    );
  }

  Future<void> _copySensitiveBackup() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dl10n = AppLocalizations.of(dialogContext)!;
            return AlertDialog(
              title: Text(dl10n.copySensitiveBackupTitle),
              content: Text(dl10n.copySensitiveBackupConfirm),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dl10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(dl10n.copy),
                ),
              ],
            );
          },
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
      SnackBar(content: Text(AppLocalizations.of(context)!.sensitiveBackupCopied)),
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
          builder: (dialogContext) {
            final dl10n = AppLocalizations.of(dialogContext)!;
            return AlertDialog(
              title: Text(dl10n.revealSensitiveBackupTitle),
              content: Text(dl10n.revealSensitiveBackupConfirm),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dl10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(dl10n.reveal),
                ),
              ],
            );
          },
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
