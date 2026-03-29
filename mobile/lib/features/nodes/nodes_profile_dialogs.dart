import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'nodes_config_validation.dart';
import 'nodes_dialog_models.dart';

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
    return AlertDialog(
      title: const Text('Import from URL'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  hintText: 'e.g. My Subscription',
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
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL',
                  hintText: 'https://example.com/sub?token=...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                validator: (value) {
                  final url = value?.trim() ?? '';
                  if (url.isEmpty) {
                    return 'Please enter a subscription URL';
                  }
                  final uri = Uri.tryParse(url);
                  final isValidHttpUri = uri != null &&
                      uri.hasAuthority &&
                      (uri.scheme == 'http' || uri.scheme == 'https');
                  if (!isValidHttpUri) {
                    return 'Please enter a valid http(s) URL';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
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
          child: const Text('Import'),
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
    return AlertDialog(
      title: const Text('Create Profile'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  hintText: 'e.g. My VPN Config',
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return 'Please enter a profile name';
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
                decoration: const InputDecoration(
                  labelText: 'sing-box JSON Config',
                  hintText: 'Paste sing-box configuration JSON here...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 8,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.sp,
                ),
                validator: (value) {
                  final config = value?.trim() ?? '';
                  if (config.isEmpty) {
                    return 'Please paste a sing-box config';
                  }
                  return validateSingboxConfig(config);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
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
          child: const Text('Create'),
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
    return AlertDialog(
      title: const Text('Rename Profile'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Profile Name'),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) {
              return 'Please enter a profile name';
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
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.pop(context, _nameController.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
