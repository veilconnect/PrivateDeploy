import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import 'nodes_dialog_models.dart';

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
  var _cancelled = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _cancelled = true;
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
          onPressed: () {
            _cancelled = true;
            Navigator.pop(context, false);
          },
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving
              ? null
              : () async {
                  setState(() {
                    _isSaving = true;
                    _cancelled = false;
                    _dialogError = null;
                  });

                  final error =
                      await widget.onVerifyAndSave(_controller.text.trim());
                  if (!mounted || _cancelled) {
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final provider = context.read<CloudProvider>();
      if (provider.regions.isEmpty && !provider.isLoadingRegions) {
        unawaited(provider.loadRegions());
      }
      if (provider.plans.isEmpty && !provider.isLoadingPlans) {
        unawaited(provider.loadPlans());
      }
    });
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
    final isLoadingOptions =
        provider.isLoadingRegions || provider.isLoadingPlans;
    final missingRegions = provider.regions.isEmpty;
    final missingPlans = provider.plans.isEmpty;
    final canDeploy =
        !missingRegions && !missingPlans && _selectedRegion != null && _selectedPlan != null;

    return AlertDialog(
      title: const Text('Deploy Node'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (missingRegions || missingPlans)
              Container(
                width: double.infinity,
                margin: EdgeInsets.only(bottom: 16.h),
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isLoadingOptions) ...[
                          SizedBox(
                            width: 16.w,
                            height: 16.w,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 8.w),
                        ] else
                          const Icon(Icons.cloud_off_outlined, size: 18),
                        Expanded(
                          child: Text(
                            isLoadingOptions
                                ? 'Loading regions and plans...'
                                : provider.error ??
                                    'Deployment options are unavailable right now.',
                            style: TextStyle(fontSize: 12.sp),
                          ),
                        ),
                      ],
                    ),
                    if (!isLoadingOptions) ...[
                      SizedBox(height: 10.h),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            unawaited(provider.loadRegions());
                            unawaited(provider.loadPlans());
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry Loading'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Node Name (Optional)',
                hintText: 'Auto-generate if left blank',
              ),
            ),
            SizedBox(height: 16.h),
            DropdownButtonFormField<String>(
              value: _selectedRegion,
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
              onChanged: missingRegions
                  ? null
                  : (value) {
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
              value: _selectedPlan,
              decoration: InputDecoration(
                labelText: 'Plan',
                helperText:
                    !missingPlans && _selectedRegion != null && availablePlans.isEmpty
                    ? 'No supported plans are available in this region.'
                    : null,
              ),
              isExpanded: true,
              items: availablePlans
                  .map(
                    (plan) => DropdownMenuItem(
                      value: plan.id,
                      child: Text(plan.displayName),
                    ),
                  )
                  .toList(),
              onChanged: missingPlans || availablePlans.isEmpty
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
          onPressed: !canDeploy
              ? null
              : () {
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
          child: Text(isLoadingOptions && !canDeploy ? 'Loading...' : 'Deploy'),
        ),
      ],
    );
  }
}
