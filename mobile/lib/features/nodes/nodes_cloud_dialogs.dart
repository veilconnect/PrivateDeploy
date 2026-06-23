import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cdn/cdn_provider.dart';
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
  // Set once we've auto-selected the fastest reachable region, so a later
  // rebuild (e.g. probes finishing) doesn't keep overriding the user's choice.
  bool _autoSelectedRegion = false;
  // Set once we've kicked the per-region reachability probe. Gated on regions
  // actually being present, so it fires whether they were cached, freshly
  // loaded, or arrived from a load already in flight when the dialog opened.
  bool _regionProbeKicked = false;
  // Default true so the common case (CDN already set up) saves the user
  // a second trip. When CDN isn't verified the checkbox is hidden and
  // this stays false. Only the user un-checking it sets it to false
  // while CDN is verified.
  bool _autoDeployCdn = true;

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
      unawaited(_ensureDeployOptions(context.read<CloudProvider>()));
    });
  }

  /// Loads regions/plans if needed. Mirrors the original guards (don't kick a
  /// fresh load while one is already in flight). Per-region reachability
  /// probing is kicked separately from [build] once regions are actually
  /// present — see [_maybeKickRegionProbe] — so it also covers the case where
  /// a load was already running when the dialog opened.
  Future<void> _ensureDeployOptions(CloudProvider provider) async {
    if (provider.regions.isEmpty && !provider.isLoadingRegions) {
      await provider.loadRegions();
    }
    if (provider.plans.isEmpty && !provider.isLoadingPlans) {
      unawaited(provider.loadPlans());
    }
  }

  /// Kicks the per-region reachability probe exactly once, as soon as regions
  /// are present. Runs from the device's current network — the same path the
  /// new node would dial — so a region whose anchor times out is flagged
  /// unreachable. Idempotent: [CloudProvider.probeRegionLatencies] caches and
  /// guards against concurrent runs.
  void _maybeKickRegionProbe(CloudProvider provider) {
    if (_regionProbeKicked || provider.regions.isEmpty) {
      return;
    }
    _regionProbeKicked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(context.read<CloudProvider>().probeRegionLatencies());
    });
  }

  /// Regions ordered for the dropdown: reachable first (fastest first), then
  /// still-probing/unknown, then unreachable last. Within a tier, by name.
  List<CloudRegion> _sortedRegions(CloudProvider provider) {
    int rank(CloudLatencyCheck? check) {
      if (check == null || check.isTesting) {
        return 1;
      }
      if (check.error != null || check.latencyMs == null) {
        return 2;
      }
      return 0;
    }

    final sorted = [...provider.regions];
    sorted.sort((a, b) {
      final ca = provider.regionLatencyFor(a.id);
      final cb = provider.regionLatencyFor(b.id);
      final ra = rank(ca);
      final rb = rank(cb);
      if (ra != rb) {
        return ra.compareTo(rb);
      }
      if (ra == 0) {
        return ca!.latencyMs!.compareTo(cb!.latencyMs!);
      }
      return a.displayName.compareTo(b.displayName);
    });
    return sorted;
  }

  /// Once probing has settled, pre-select the fastest reachable region if the
  /// user hasn't picked one yet. Scheduled post-frame so it doesn't mutate
  /// state mid-build.
  void _maybeAutoSelectRegion(CloudProvider provider) {
    if (_autoSelectedRegion ||
        _selectedRegion != null ||
        provider.isProbingRegions) {
      return;
    }
    final fastest = provider.fastestReachableRegionId();
    if (fastest == null) {
      return;
    }
    _autoSelectedRegion = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedRegion != null) {
        return;
      }
      setState(() {
        _selectedRegion = fastest;
        final availablePlanIds = _availablePlans(provider, fastest)
            .map((plan) => plan.id)
            .toSet();
        if (_selectedPlan != null &&
            !availablePlanIds.contains(_selectedPlan)) {
          _selectedPlan = null;
        }
      });
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
    if (!isSsh) {
      _maybeKickRegionProbe(provider);
      _maybeAutoSelectRegion(provider);
    }
    final sortedRegions = _sortedRegions(provider);
    final availablePlans = _availablePlans(provider, _selectedRegion);
    final isLoadingOptions =
        provider.isLoadingRegions || provider.isLoadingPlans;
    final missingRegions = provider.regions.isEmpty;
    final missingPlans = provider.plans.isEmpty;
    final accountStatus = provider.accountStatus;
    final accountBlocksDeploy = accountStatus?.canDeploy == false;
    final canDeploy = isSsh
        ? provider.hasStoredApiKey
        : !missingRegions &&
            !missingPlans &&
            _selectedRegion != null &&
            _selectedPlan != null &&
            !accountBlocksDeploy;

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
            if (!isSsh && accountStatus != null)
              _AccountStatusBanner(status: accountStatus),
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
                decoration: InputDecoration(
                  labelText: l10n.region,
                  helperText:
                      provider.isProbingRegions ? l10n.regionProbing : null,
                ),
                isExpanded: true,
                // Closed field shows just the region name; the latency chip
                // would overflow the single-line selection box.
                selectedItemBuilder: (context) => sortedRegions
                    .map(
                      (region) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          region.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                items: sortedRegions
                    .map(
                      (region) => DropdownMenuItem(
                        value: region.id,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                region.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(width: 8.w),
                            _RegionLatencyChip(
                              check: provider.regionLatencyFor(region.id),
                            ),
                          ],
                        ),
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
            // CDN-worker auto-deploy opt-out. Only shown when CDN is fully
            // configured (token verified) — otherwise the option is
            // meaningless and would just confuse new users. SSH-provisioned
            // nodes don't get a CF worker either (M1 is cloud-provider-
            // specific), so we hide it on SSH too.
            if (!isSsh &&
                context.watch<CdnProvider>().status == CdnStatus.verified) ...[
              SizedBox(height: 16.h),
              CheckboxListTile(
                value: _autoDeployCdn,
                onChanged: (v) => setState(() => _autoDeployCdn = v ?? false),
                title: Text(l10n.deployCdnWorkerAfterCreate),
                subtitle: Text(
                  l10n.deployCdnWorkerAfterCreateHint,
                  style: TextStyle(fontSize: 11.sp),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
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
                      autoDeployCdnWorker: !isSsh && _autoDeployCdn,
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

/// Trailing reachability/latency indicator for a region dropdown item.
/// Spinner while probing, green/amber/red latency when reachable, red
/// "Unreachable" when the current network can't reach the region's anchor,
/// nothing when the region has no anchor to probe.
class _RegionLatencyChip extends StatelessWidget {
  const _RegionLatencyChip({required this.check});

  final CloudLatencyCheck? check;

  @override
  Widget build(BuildContext context) {
    final value = check;
    if (value == null) {
      return const SizedBox.shrink();
    }
    if (value.isTesting) {
      return SizedBox(
        width: 12.w,
        height: 12.w,
        child: const CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    final l10n = AppLocalizations.of(context)!;
    final ms = value.latencyMs;
    if (value.error != null || ms == null) {
      return Text(
        l10n.regionUnreachable,
        style: TextStyle(fontSize: 11.sp, color: Colors.red),
      );
    }
    final color = ms < 150
        ? Colors.green
        : ms < 300
            ? Colors.orange
            : Colors.redAccent;
    return Text(
      '$ms ms',
      style: TextStyle(fontSize: 11.sp, color: color),
    );
  }
}

/// Inline account-status callout for the deploy dialog. Mirrors the desktop
/// CloudView banner: locked → red, warning → amber, active/unknown → hidden.
/// Soft-locked (state=locked, canDeploy=true) keeps the red title but the
/// caller leaves the deploy button enabled — Vultr's "cap reached but reusable
/// PrivateDeploy group exists" path.
class _AccountStatusBanner extends StatelessWidget {
  const _AccountStatusBanner({required this.status});

  final CloudAccountStatus status;

  @override
  Widget build(BuildContext context) {
    final isLocked = status.state == CloudAccountState.locked ||
        status.state == CloudAccountState.invalidKey;
    final isWarning = status.state == CloudAccountState.warning;
    if (!isLocked && !isWarning) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final isSoftLocked = isLocked && status.canDeploy;
    final color = isLocked ? Colors.red : Colors.orange;

    final String title;
    if (isWarning) {
      title = l10n.accountStatusWarningTitle;
    } else {
      title = l10n.accountStatusLockedTitle;
    }

    final String hint;
    if (isWarning) {
      hint = l10n.accountStatusWarningHint;
    } else if (isSoftLocked) {
      hint = l10n.accountStatusLockedSoftHint;
    } else {
      hint = l10n.accountStatusLockedHint;
    }

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 12.h),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
              color: color[800],
            ),
          ),
          if (status.message.isNotEmpty) ...[
            SizedBox(height: 4.h),
            Text(
              status.message,
              style: TextStyle(fontSize: 12.sp, color: color[800]),
            ),
          ],
          SizedBox(height: 4.h),
          Text(
            hint,
            style: TextStyle(fontSize: 12.sp, color: color[700]),
          ),
        ],
      ),
    );
  }
}
