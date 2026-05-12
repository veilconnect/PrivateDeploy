import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';

Future<String?> showSharePassphraseDialog({
  required BuildContext context,
  required String title,
  required String message,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SharePassphraseDialog(title: title, message: message),
  );
}

class _SharePassphraseDialog extends StatefulWidget {
  const _SharePassphraseDialog({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  State<_SharePassphraseDialog> createState() => _SharePassphraseDialogState();
}

class _SharePassphraseDialogState extends State<_SharePassphraseDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _passphraseController;
  late final TextEditingController _confirmController;
  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;

  @override
  void initState() {
    super.initState();
    _passphraseController = TextEditingController();
    _confirmController = TextEditingController();
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      // Scrollable content + autovalidate-on-interaction so the second
      // password field stays tappable when the IME pushes the dialog up.
      // Without the scroll view, AlertDialog clips the inactive field
      // behind the keyboard's touch-dead inset, and taps in that band are
      // eaten by the IME instead of focusing the field.
      scrollable: true,
      content: SizedBox(
        width: 480.w,
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.message),
              SizedBox(height: 16.h),
              TextFormField(
                controller: _passphraseController,
                obscureText: _obscurePassphrase,
                decoration: InputDecoration(
                  labelText: l10n.sharePassphrase,
                  border: const OutlineInputBorder(),
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
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return l10n.passphraseRequired;
                  }
                  return null;
                },
              ),
              SizedBox(height: 12.h),
              TextFormField(
                controller: _confirmController,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  labelText: l10n.confirmSharePassphrase,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirm
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureConfirm = !_obscureConfirm;
                      });
                    },
                  ),
                ),
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return l10n.passphraseRequired;
                  }
                  if (value!.trim() != _passphraseController.text.trim()) {
                    return l10n.passphraseMismatch;
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.pop(context, _passphraseController.text.trim());
          },
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}
