import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import 'nodes_config_validation.dart';

typedef NodesProfileNameValidator = String? Function(String name);

class NodesImportProfileRequest {
  final String name;
  final String url;

  const NodesImportProfileRequest({
    required this.name,
    required this.url,
  });
}

class NodesCreateProfileRequest {
  final String name;
  final String config;

  const NodesCreateProfileRequest({
    required this.name,
    required this.config,
  });
}

class NodesCreateCloudRequest {
  final String label;
  final String region;
  final String plan;

  const NodesCreateCloudRequest({
    required this.label,
    required this.region,
    required this.plan,
  });
}

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

Future<bool> showNodesCloudApiKeyDialog({
  required BuildContext context,
  required String initialValue,
  required Future<String?> Function(String apiKey) onVerifyAndSave,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => _NodesCloudApiKeyDialog(
          initialValue: initialValue,
          onVerifyAndSave: onVerifyAndSave,
        ),
      ) ??
      false;
}

Future<NodesCreateCloudRequest?> showNodesCreateCloudDialog(
  BuildContext context,
) {
  return showDialog<NodesCreateCloudRequest>(
    context: context,
    builder: (context) => const _NodesCreateCloudDialog(),
  );
}

Future<bool> showNodesDeleteConfirmationDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

Future<CloudInstance?> showNodesCloudNodePickerSheet(
  BuildContext context,
  List<CloudInstance> candidates,
) {
  return showModalBottomSheet<CloudInstance>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose a cloud node',
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 6.h),
              Text(
                'Connect needs one active node. Pick which cloud node to use now.',
                style: TextStyle(
                  fontSize: 13.sp,
                  color: Colors.grey[700],
                ),
              ),
              SizedBox(height: 12.h),
              ...candidates.map(
                (instance) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_done, color: Colors.green),
                  title: Text(instance.label),
                  subtitle: Text(
                    '${instance.region}${instance.ipv4 != null ? ' • ${instance.ipv4}' : ''}',
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(instance),
                ),
              ),
            ],
          ),
        ),
      );
    },
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

class _NodesCloudApiKeyDialog extends StatefulWidget {
  final String initialValue;
  final Future<String?> Function(String apiKey) onVerifyAndSave;

  const _NodesCloudApiKeyDialog({
    required this.initialValue,
    required this.onVerifyAndSave,
  });

  @override
  State<_NodesCloudApiKeyDialog> createState() => _NodesCloudApiKeyDialogState();
}

class _NodesCloudApiKeyDialogState extends State<_NodesCloudApiKeyDialog> {
  late final TextEditingController _controller;
  var _isSaving = false;
  String? _dialogError;

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
      title: const Text('Cloud API Key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: 'Enter your cloud provider API key',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_isSaving,
          ),
          if (_dialogError != null) ...[
            const SizedBox(height: 12),
            Text(
              _dialogError!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving
              ? null
              : () async {
                  setState(() {
                    _isSaving = true;
                    _dialogError = null;
                  });

                  final error =
                      await widget.onVerifyAndSave(_controller.text.trim());
                  if (!mounted) {
                    return;
                  }

                  if (error == null) {
                    Navigator.pop(context, true);
                  } else {
                    setState(() {
                      _dialogError = error;
                      _isSaving = false;
                    });
                  }
                },
          child: _isSaving
              ? const Text('Verifying...')
              : const Text('Verify & Save'),
        ),
      ],
    );
  }
}

class _NodesCreateCloudDialog extends StatefulWidget {
  const _NodesCreateCloudDialog();

  @override
  State<_NodesCreateCloudDialog> createState() => _NodesCreateCloudDialogState();
}

class _NodesCreateCloudDialogState extends State<_NodesCreateCloudDialog> {
  late final TextEditingController _labelController;
  String? _selectedRegion;
  String? _selectedPlan;

  List<CloudPlan> _availablePlans(CloudProvider provider, String? region) {
    return provider.plans
        .where((plan) => region == null || plan.locations.contains(region))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController();
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudProvider>();
    final availablePlans = _availablePlans(provider, _selectedRegion);

    return AlertDialog(
      title: const Text('Deploy Node'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Node Name (Optional)',
                hintText: 'Auto-generate if left blank',
              ),
            ),
            SizedBox(height: 16.h),
            DropdownButtonFormField<String>(
              initialValue: _selectedRegion,
              decoration: const InputDecoration(labelText: 'Region'),
              isExpanded: true,
              items: provider.regions
                  .map(
                    (region) => DropdownMenuItem(
                      value: region.id,
                      child: Text(region.displayName),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedRegion = value;
                  final availablePlanIds = _availablePlans(provider, value)
                      .map((plan) => plan.id)
                      .toSet();
                  if (_selectedPlan != null &&
                      !availablePlanIds.contains(_selectedPlan)) {
                    _selectedPlan = null;
                  }
                });
              },
            ),
            SizedBox(height: 16.h),
            DropdownButtonFormField<String>(
              initialValue: _selectedPlan,
              decoration: const InputDecoration(labelText: 'Plan'),
              isExpanded: true,
              items: availablePlans
                  .map(
                    (plan) => DropdownMenuItem(
                      value: plan.id,
                      child: Text(plan.displayName),
                    ),
                  )
                  .toList(),
              onChanged: availablePlans.isEmpty
                  ? null
                  : (value) => setState(() => _selectedPlan = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_selectedRegion == null || _selectedPlan == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please select region and plan'),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }
            final hasValidPlan = availablePlans.any(
              (plan) => plan.id == _selectedPlan,
            );
            if (!hasValidPlan) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Selected plan is not available in the chosen region',
                  ),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }

            Navigator.pop(
              context,
              NodesCreateCloudRequest(
                label: _labelController.text.trim(),
                region: _selectedRegion!,
                plan: _selectedPlan!,
              ),
            );
          },
          child: const Text('Deploy'),
        ),
      ],
    );
  }
}
