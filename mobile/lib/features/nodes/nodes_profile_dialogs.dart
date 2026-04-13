import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialog_models.dart';
import 'nodes_test_keys.dart';

Future<NodesImportProfileRequest?> showNodesImportProfileDialog(
  BuildContext context, {
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<NodesImportProfileRequest>(
    context: context,
    builder: (context) => _NodesImportProfileDialog(validateName: validateName),
  );
}

Future<NodesCreateProfileRequest?> showNodesCreateProfileDialog(
  BuildContext context, {
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<NodesCreateProfileRequest>(
    context: context,
    builder: (context) => _NodesCreateProfileDialog(validateName: validateName),
  );
}

Future<String?> showNodesRenameProfileDialog({
  required BuildContext context,
  required String initialName,
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NodesRenameProfileDialog(
      initialName: initialName,
      validateName: validateName,
    ),
  );
}

class _NodesImportProfileDialog extends StatefulWidget {
  final NodesProfileNameValidator? validateName;

  const _NodesImportProfileDialog({
    this.validateName,
  });

  @override
  State<_NodesImportProfileDialog> createState() =>
      _NodesImportProfileDialogState();
}

class _NodesImportProfileDialogState extends State<_NodesImportProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _nameController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.importFromUrl),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: NodesTestKeys.importProfileNameField,
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.profileName,
                  hintText: l10n.egMySubscription,
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return null;
                  }
                  return widget.validateName?.call(name);
                },
              ),
              SizedBox(height: 16.h),
              TextFormField(
                key: NodesTestKeys.importProfileUrlField,
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: l10n.urlOrProxyLinks,
                  hintText: l10n.urlOrProxyLinksHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    tooltip: l10n.pasteFromClipboard,
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null && data!.text!.isNotEmpty) {
                        _urlController.text = data.text!;
                      }
                    },
                  ),
                ),
                maxLines: 3,
                validator: (value) {
                  final input = value?.trim() ?? '';
                  if (input.isEmpty) {
                    return l10n.pleaseEnterUrlOrLinks;
                  }
                  // Accept http(s) subscription URL
                  final uri = Uri.tryParse(input);
                  final isValidHttpUri = uri != null &&
                      uri.hasAuthority &&
                      (uri.scheme == 'http' || uri.scheme == 'https');
                  if (isValidHttpUri) return null;
                  // Accept proxy URI links
                  final configError = validateNodeConfig(input);
                  if (configError == null) return null;
                  return l10n.enterHttpUrlOrLinks;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          key: NodesTestKeys.importProfileSubmitButton,
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.pop(
              context,
              NodesImportProfileRequest(
                name: _nameController.text.trim(),
                url: _urlController.text.trim(),
              ),
            );
          },
          child: Text(l10n.import_),
        ),
      ],
    );
  }
}

class _NodesCreateProfileDialog extends StatefulWidget {
  final NodesProfileNameValidator? validateName;

  const _NodesCreateProfileDialog({
    this.validateName,
  });

  @override
  State<_NodesCreateProfileDialog> createState() =>
      _NodesCreateProfileDialogState();
}

class _NodesCreateProfileDialogState extends State<_NodesCreateProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _configController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _configController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _configController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.createProfile),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.profileName,
                  hintText: l10n.egMyVpnConfig,
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return l10n.pleaseEnterProfileName;
                  }
                  final validationError = widget.validateName?.call(name);
                  if (validationError != null) {
                    return validationError;
                  }
                  return null;
                },
              ),
              SizedBox(height: 16.h),
              TextFormField(
                controller: _configController,
                decoration: InputDecoration(
                  labelText: l10n.config,
                  hintText: l10n.pasteProxyLinksOrJson,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    tooltip: l10n.pasteFromClipboard,
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null && data!.text!.isNotEmpty) {
                        _configController.text = data.text!;
                      }
                    },
                  ),
                ),
                maxLines: 8,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.sp,
                ),
                validator: (value) {
                  final config = value?.trim() ?? '';
                  if (config.isEmpty) {
                    return l10n.pleasePasteConfig;
                  }
                  return validateNodeConfig(config);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.pop(
              context,
              NodesCreateProfileRequest(
                name: _nameController.text.trim(),
                config: _configController.text.trim(),
              ),
            );
          },
          child: Text(l10n.create),
        ),
      ],
    );
  }
}

class _NodesRenameProfileDialog extends StatefulWidget {
  final String initialName;
  final NodesProfileNameValidator? validateName;

  const _NodesRenameProfileDialog({
    required this.initialName,
    this.validateName,
  });

  @override
  State<_NodesRenameProfileDialog> createState() =>
      _NodesRenameProfileDialogState();
}

class _NodesRenameProfileDialogState extends State<_NodesRenameProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.renameProfile),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          decoration: InputDecoration(labelText: l10n.profileName),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) {
              return l10n.pleaseEnterProfileName;
            }
            final validationError = widget.validateName?.call(name);
            if (validationError != null) {
              return validationError;
            }
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.pop(context, _nameController.text.trim());
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
