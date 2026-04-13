import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_backup.dart';
import '../cloud/cloud_provider.dart';
import 'settings_backup_preview_card.dart';

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
  CloudBackupPreview? _preview;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.addListener(_syncPreview);
    _preview = _tryBuildPreview(widget.initialValue.trim());
    _dialogError = _preview == null && widget.initialValue.trim().isNotEmpty
        ? _validationMessageFor(widget.initialValue.trim())
        : null;
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPreview);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.restoreCloudBackupTitle),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.restoreCloudBackupDesc2),
            SizedBox(height: 12.h),
            TextField(
              controller: _controller,
              minLines: 10,
              maxLines: 14,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: l10n.pasteCloudBackupHint,
                errorText: _dialogError,
              ),
            ),
            if (_preview != null) ...[
              SizedBox(height: 12.h),
              SettingsBackupPreviewCard(
                preview: _preview!,
                title: 'Restore Preview',
              ),
            ],
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _restoring ? null : () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
        FilledButton.tonal(
          onPressed: _restoring ? null : _pasteClipboard,
          child: Text(l10n.pasteClipboard),
        ),
        FilledButton(
          onPressed: _restoring || _preview == null ? null : _restoreBackup,
          child: _restoring
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.restore),
        ),
      ],
    );
  }

  Future<void> _pasteClipboard() async {
    final latest = await Clipboard.getData('text/plain');
    if (!mounted) {
      return;
    }
    _controller.text = latest?.text ?? '';
  }

  void _syncPreview() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _preview = null;
        _dialogError = null;
      });
      return;
    }

    final preview = _tryBuildPreview(raw);
    final validationMessage =
        preview == null ? _validationMessageFor(raw) : null;
    if (!mounted) {
      return;
    }
    setState(() {
      _preview = preview;
      _dialogError = validationMessage;
    });
  }

  CloudBackupPreview? _tryBuildPreview(String raw) {
    try {
      return inspectCloudBackupJson(
        raw,
        expectedProvider: widget.cloud.providerName,
      );
    } catch (_) {
      return null;
    }
  }

  String? _validationMessageFor(String raw) {
    try {
      inspectCloudBackupJson(
        raw,
        expectedProvider: widget.cloud.providerName,
      );
      return null;
    } catch (e) {
      return e.toString().replaceFirst('FormatException: ', '');
    }
  }

  Future<void> _restoreBackup() async {
    final raw = _controller.text.trim();
    final l10n = AppLocalizations.of(context)!;
    if (raw.isEmpty) {
      setState(() {
        _dialogError = l10n.backupJsonEmpty;
      });
      return;
    }

    final preview = _preview;
    if (preview == null) {
      setState(() {
        _dialogError ??= l10n.backupJsonInvalid;
      });
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dl10n = AppLocalizations.of(dialogContext)!;
            return AlertDialog(
              title: Text(dl10n.restoreThisBackupTitle),
              content: SizedBox(
                width: 460.w,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dl10n.restoreThisBackupConfirm),
                    SizedBox(height: 12.h),
                    SettingsBackupPreviewCard(
                      preview: preview,
                      title: 'Backup To Restore',
                    ),
                  ],
                ),
              ),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dl10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(dl10n.restore),
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
          SnackBar(content: Text(AppLocalizations.of(widget.rootContext)!.cloudBackupRestored)),
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
