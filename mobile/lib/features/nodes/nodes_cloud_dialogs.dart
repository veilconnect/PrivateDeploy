import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../cloud/ssh_deployer.dart';
import 'nodes_dialog_models.dart';

Future<NodesCreateCloudRequest?> showNodesCreateCloudDialog(
  BuildContext context,
) {
  return showDialog<NodesCreateCloudRequest>(
    context: context,
    builder: (context) => const _NodesCreateCloudDialog(),
  );
}

class _NodesCreateCloudDialog extends StatefulWidget {
  const _NodesCreateCloudDialog();

  @override
  State<_NodesCreateCloudDialog> createState() =>
      _NodesCreateCloudDialogState();
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
    final isSsh = provider.providerId == CloudProviderId.ssh;
    final availablePlans = _availablePlans(provider, _selectedRegion);
    final isLoadingOptions =
        provider.isLoadingRegions || provider.isLoadingPlans;
    final missingRegions = provider.regions.isEmpty;
    final missingPlans = provider.plans.isEmpty;
    final canDeploy = isSsh
        ? provider.hasStoredApiKey
        : !missingRegions &&
            !missingPlans &&
            _selectedRegion != null &&
            _selectedPlan != null;

    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.deployNodeTitle),
      // Surface which provider the instance will be created under. Prevents
      // the confusion case where a user on DigitalOcean opens the dialog
      // expecting Vultr regions/plans — the subtitle makes it explicit
      // before they pick anything.
      contentPadding: EdgeInsets.fromLTRB(24.w, 12.h, 24.w, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: 8.h),
              child: Text(
                isSsh
                    ? l10n.deployToSshServer(
                        provider.providerExtra.isEmpty
                            ? provider.providerDisplayName
                            : sshAccessSummary(provider.providerExtra),
                      )
                    : l10n.deployToCloudProvider(provider.providerDisplayName),
                style: TextStyle(
                  fontSize: 12.sp,
                  color: Colors.black54,
                ),
              ),
            ),
            if (!isSsh && (missingRegions || missingPlans))
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
                                ? l10n.loadingRegionsPlans
                                : provider.error ?? l10n.deploymentUnavailable,
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
                          label: Text(l10n.retryLoading),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            TextField(
              controller: _labelController,
              decoration: InputDecoration(
                labelText: l10n.nodeNameOptional,
                hintText: l10n.autoGenerateHint,
              ),
            ),
            if (isSsh) ...[
              SizedBox(height: 14.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Text(
                  provider.hasStoredApiKey
                      ? l10n.sshDeployUsesSavedAccess(
                          sshAccessSummary(provider.providerExtra),
                        )
                      : l10n.setSshAccessHint,
                  style: TextStyle(fontSize: 12.sp),
                ),
              ),
            ] else ...[
              SizedBox(height: 16.h),
              DropdownButtonFormField<String>(
                initialValue: _selectedRegion,
                decoration: InputDecoration(labelText: l10n.region),
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
                          final availablePlanIds =
                              _availablePlans(provider, value)
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
                decoration: InputDecoration(
                  labelText: l10n.plan,
                  helperText: !missingPlans &&
                          _selectedRegion != null &&
                          availablePlans.isEmpty
                      ? l10n.noPlansInRegion
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: !canDeploy
              ? null
              : () {
                  if (_selectedRegion == null || _selectedPlan == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.selectRegionAndPlan),
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
                      SnackBar(
                        content: Text(l10n.planNotAvailableInRegion),
                        backgroundColor: Colors.orange,
                      ),
                    );
                    return;
                  }

                  Navigator.pop(
                    context,
                    NodesCreateCloudRequest(
                      label: _labelController.text.trim(),
                      region: isSsh ? '' : _selectedRegion!,
                      plan: isSsh ? '' : _selectedPlan!,
                      usesSavedSshAccess: isSsh,
                    ),
                  );
                },
          child:
              Text(isLoadingOptions && !canDeploy ? l10n.loading : l10n.deploy),
        ),
      ],
    );
  }
}
