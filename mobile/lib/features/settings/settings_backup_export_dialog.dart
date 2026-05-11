import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/security/encrypted_share.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/share_passphrase_dialog.dart';
import '../cdn/cdn_provider.dart';
import '../cloud/cloud_backup.dart';
import '../cloud/cloud_provider.dart';
import 'settings_backup_preview_card.dart';

Future<void> showSettingsBackupExportDialog({
  required BuildContext context,
  required CloudProvider cloud,
  CdnProvider? cdn,
}) async {
  // Cloud provider encodes its own JSON; if CDN state is loaded we
  // re-emit through createCloudBackupJson with the cdn block merged in
  // so both halves round-trip through one encrypted blob. Skipping the
  // merge when cdnSnap is null keeps legacy backups byte-identical.
  String payload = await cloud.exportBackupJson();
  final cdnSnap = cdn == null ? null : await cdn.exportSnapshot();
  if (cdnSnap != null) {
    final parsed = parseCloudBackupJson(
      payload,
      expectedProvider: cloud.providerName,
    );
    payload = createCloudBackupJson(
      provider: parsed.provider,
      apiKey: parsed.apiKey,
      extra: parsed.extra,
      nodeRecords: parsed.nodeRecords,
      exportedAt: parsed.exportedAt.isEmpty
          ? null
          : DateTime.tryParse(parsed.exportedAt),
      cdn: cdnSnap,
    );
  }
  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupExportDialog(
      payload: payload,
      expectedProvider: cloud.providerName,
    ),
  );
}

class _SettingsBackupExportDialog extends StatefulWidget {
  const _SettingsBackupExportDialog({
    required this.payload,
    required this.expectedProvider,
  });

  final String payload;
  final String expectedProvider;

  @override
  State<_SettingsBackupExportDialog> createState() =>
      _SettingsBackupExportDialogState();
}

class _SettingsBackupExportDialogState
    extends State<_SettingsBackupExportDialog> {
  late final CloudBackupPreview _preview;
  bool _revealed = false;
  bool _copied = false;
  String? _revealedPayload;

  @override
  void initState() {
    super.initState();
    _preview = inspectCloudBackupJson(
      widget.payload,
      expectedProvider: widget.expectedProvider,
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
                  child: SelectableText(_revealedPayload ?? ''),
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
    final l10n = AppLocalizations.of(context)!;
    final passphrase = await showSharePassphraseDialog(
      context: context,
      title: l10n.copySensitiveBackupTitle,
      message: l10n.copySensitiveBackupConfirm,
    );
    if (passphrase == null || !mounted) {
      return;
    }

    final armored = await EncryptedShareCodec.encrypt(
      kind: EncryptedShareKind.cloudBackup,
      content: widget.payload,
      passphrase: passphrase,
      label: widget.expectedProvider,
    );
    await Clipboard.setData(ClipboardData(text: armored));
    if (!mounted) {
      return;
    }

    setState(() {
      _copied = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppLocalizations.of(context)!.sensitiveBackupCopied)),
    );
  }

  Future<void> _toggleSensitiveJson() async {
    if (_revealed) {
      setState(() {
        _revealed = false;
        _revealedPayload = null;
      });
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final passphrase = await showSharePassphraseDialog(
      context: context,
      title: l10n.revealSensitiveBackupTitle,
      message: l10n.revealSensitiveBackupConfirm,
    );
    if (passphrase == null || !mounted) {
      return;
    }

    final armored = await EncryptedShareCodec.encrypt(
      kind: EncryptedShareKind.cloudBackup,
      content: widget.payload,
      passphrase: passphrase,
      label: widget.expectedProvider,
    );
    setState(() {
      _revealed = true;
      _revealedPayload = armored;
    });
  }
}
