import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/security/encrypted_share.dart';
import '../../l10n/app_localizations.dart';
import '../cdn/cdn_provider.dart';
import '../cloud/cloud_backup.dart';
import '../cloud/cloud_provider.dart';
import 'settings_backup_preview_card.dart';

Future<void> showSettingsBackupImportDialog({
  required BuildContext context,
  required CloudProvider cloud,
  CdnProvider? cdn,
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
      cdn: cdn,
      initialValue: clipboard?.text ?? '',
    ),
  );
}

class _SettingsBackupImportDialog extends StatefulWidget {
  const _SettingsBackupImportDialog({
    required this.rootContext,
    required this.cloud,
    required this.cdn,
    required this.initialValue,
  });

  final BuildContext rootContext;
  final CloudProvider cloud;
  final CdnProvider? cdn;
  final String initialValue;

  @override
  State<_SettingsBackupImportDialog> createState() =>
      _SettingsBackupImportDialogState();
}

class _SettingsBackupImportDialogState
    extends State<_SettingsBackupImportDialog> {
  late final TextEditingController _controller;
  late final TextEditingController _passphraseController;
  String? _dialogError;
  CloudBackupPreview? _preview;
  bool _restoring = false;
  bool _obscurePassphrase = true;
  int _previewSequence = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _passphraseController = TextEditingController();
    _controller.addListener(_syncPreview);
    _passphraseController.addListener(_syncPreview);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPreview();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPreview);
    _passphraseController.removeListener(_syncPreview);
    _controller.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dialogMaxHeight = MediaQuery.of(context).size.height * 0.68;
    return AlertDialog(
      title: Text(l10n.restoreCloudBackupTitle),
      content: SizedBox(
        width: 520.w,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: dialogMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.restoreCloudBackupDesc2),
                SizedBox(height: 12.h),
                TextField(
                  controller: _controller,
                  minLines: 8,
                  maxLines: 12,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: l10n.pasteCloudBackupHint,
                    errorText: _dialogError,
                  ),
                ),
                SizedBox(height: 12.h),
                TextField(
                  controller: _passphraseController,
                  obscureText: _obscurePassphrase,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: l10n.sharePassphrase,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassphrase
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassphrase = !_obscurePassphrase;
                        });
                      },
                    ),
                  ),
                ),
                if (_preview != null) ...[
                  SizedBox(height: 12.h),
                  SettingsBackupPreviewCard(
                    preview: _preview!,
                  ),
                ],
              ],
            ),
          ),
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

  Future<void> _syncPreview() async {
    final sequence = ++_previewSequence;
    final raw = _controller.text.trim();
    final passphrase = _passphraseController.text.trim();
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

    if (passphrase.isEmpty) {
      if (!mounted || sequence != _previewSequence) {
        return;
      }
      setState(() {
        _preview = null;
        _dialogError = null;
      });
      return;
    }

    CloudBackupPreview? preview;
    String? validationMessage;
    try {
      final decrypted = await _decryptBackupPayload(raw);
      preview = inspectCloudBackupJson(
        decrypted,
        expectedProvider: widget.cloud.providerName,
      );
    } catch (e) {
      validationMessage = e.toString().replaceFirst('FormatException: ', '');
    }

    if (!mounted || sequence != _previewSequence) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _preview = preview;
      _dialogError = validationMessage;
    });
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
    if (_passphraseController.text.trim().isEmpty) {
      setState(() {
        _dialogError = l10n.passphraseRequired;
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
      final decrypted = await _decryptBackupPayload(raw);
      await widget.cloud.importBackupJson(decrypted);
      // Apply the CDN side only after cloud succeeded — if cloud
      // import threw we wouldn't want to half-restore CDN against a
      // mismatched node set. The cdn block is optional; backups
      // without it (or built by older versions) leave CDN state
      // untouched.
      final cdn = widget.cdn;
      if (cdn != null) {
        final parsed = parseCloudBackupJson(
          decrypted,
          expectedProvider: widget.cloud.providerName,
        );
        if (parsed.cdn != null) {
          await cdn.restoreSnapshot(parsed.cdn!);
        }
      }
      if (mounted) {
        Navigator.pop(context);
      }
      if (widget.rootContext.mounted) {
        ScaffoldMessenger.of(widget.rootContext).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(widget.rootContext)!
                  .cloudBackupRestored)),
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

  Future<String> _decryptBackupPayload(String raw) async {
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) {
      throw const FormatException('Passphrase is required');
    }
    final payload = await EncryptedShareCodec.decrypt(
      armored: raw,
      passphrase: passphrase,
      expectedKind: EncryptedShareKind.cloudBackup,
    );
    return payload.content;
  }
}
