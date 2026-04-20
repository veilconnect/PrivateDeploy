import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_widgets.dart';

class NodesCloudSection extends StatelessWidget {
  final CloudProvider cloudProvider;
  final ProfileProvider profileProvider;
  final VpnProvider vpnProvider;
  final VoidCallback onConfigureApiKey;
  final VoidCallback onImportProfile;
  final VoidCallback onRetryLoad;
  final VoidCallback onCreateCloudNode;
  final ValueChanged<CloudInstance> onViewDetails;
  final ValueChanged<CloudInstance> onDeleteCloudNode;
  final ValueChanged<CloudInstance> onUseCloudNode;
  final ValueChanged<CloudInstance> onTestCloudNodeLatency;
  final VoidCallback onTestAllCloudNodesLatency;
  final Future<void> Function(CloudProviderId providerId)
      onManageProviderChanged;

  const NodesCloudSection({
    Key? key,
    required this.cloudProvider,
    required this.profileProvider,
    required this.vpnProvider,
    required this.onConfigureApiKey,
    required this.onImportProfile,
    required this.onRetryLoad,
    required this.onCreateCloudNode,
    required this.onViewDetails,
    required this.onDeleteCloudNode,
    required this.onUseCloudNode,
    required this.onTestCloudNodeLatency,
    required this.onTestAllCloudNodesLatency,
    required this.onManageProviderChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final readyCloudNodes = connectableCloudInstances(cloudProvider);
    final pendingCloudNodes =
        cloudProvider.allInstances.length - readyCloudNodes.length;
    final selectedCloudProfile = profileProvider.activeProfile;
    final selectedCloudProfileName = selectedCloudProfile != null &&
            isCloudManagedProfile(selectedCloudProfile)
        ? selectedCloudProfile.name
        : l10n.noNodeSelected;
    final headerSubtitle = cloudProvider.providerId.displayName;
    if (!cloudProvider.hasApiKey &&
        cloudProvider.hasStoredApiKey &&
        cloudProvider.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NodesSectionHeader(
            title: l10n.cloudNodes,
            subtitle: headerSubtitle,
            count: cloudProvider.allInstances.length,
          ),
          SizedBox(height: 10.h),
          _CloudToolbar(
            selected: cloudProvider.providerId,
            onSelected: (providerId) {
              unawaited(onManageProviderChanged(providerId));
            },
            onCreateCloudNode: onCreateCloudNode,
            onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
            showCreateCloudNodeAction: cloudProvider.allInstances.isNotEmpty,
            showBenchmarkAction: readyCloudNodes.length > 1,
          ),
          if (cloudProvider.allInstances.isNotEmpty) ...[
            SizedBox(height: 10.h),
            _CloudOverviewMetrics(
              readyCount: readyCloudNodes.length,
              pendingCount: pendingCloudNodes,
              selectedNodeLabel: selectedCloudProfileName,
              selectedNodeHint: _selectedNodeHint(
                l10n: l10n,
                selectedNodeLabel: selectedCloudProfileName,
                readyCount: readyCloudNodes.length,
                pendingCount: pendingCloudNodes,
                providerName: cloudProvider.providerId.displayName,
              ),
            ),
          ],
          SizedBox(height: 8.h),
          NodesInlineInfoCard(
            icon: Icons.error_outline,
            title: l10n.failedToLoad,
            message: cloudProvider.error!,
            actionLabel: l10n.retry,
            onAction: onRetryLoad,
            secondaryActionLabel: l10n.setApiKey,
            onSecondaryAction: onConfigureApiKey,
            accentColor: Colors.orange,
          ),
          if (cloudProvider.allInstances.isNotEmpty) ...[
            SizedBox(height: 10.h),
            ...cloudProvider.allInstances.map(_buildCloudInstanceCard),
          ],
        ],
      );
    }

    if (!cloudProvider.hasApiKey) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NodesSectionHeader(
            title: l10n.cloudNodes,
            subtitle: headerSubtitle,
            count: 0,
          ),
          SizedBox(height: 10.h),
          _CloudToolbar(
            selected: cloudProvider.providerId,
            onSelected: (providerId) {
              unawaited(onManageProviderChanged(providerId));
            },
            onCreateCloudNode: onCreateCloudNode,
            onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
            showCreateCloudNodeAction: false,
            showBenchmarkAction: false,
          ),
          SizedBox(height: 8.h),
          NodesInlineInfoCard(
            icon: Icons.cloud_off,
            title: l10n.cloudAccessNotConfigured,
            message: l10n.setCloudProviderApiKeyHint(
                cloudProvider.providerId.displayName),
            actionLabel: l10n.setApiKey,
            onAction: onConfigureApiKey,
            secondaryActionLabel: l10n.importProfile,
            onSecondaryAction: onImportProfile,
            accentColor: const Color(0xFF1452CC),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodesSectionHeader(
          title: l10n.cloudNodes,
          subtitle: headerSubtitle,
          count: cloudProvider.allInstances.length,
        ),
        SizedBox(height: 10.h),
        _CloudToolbar(
          selected: cloudProvider.providerId,
          onSelected: (providerId) {
            unawaited(onManageProviderChanged(providerId));
          },
          onCreateCloudNode: onCreateCloudNode,
          onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
          showCreateCloudNodeAction: cloudProvider.allInstances.isNotEmpty,
          showBenchmarkAction: readyCloudNodes.length > 1,
        ),
        if (cloudProvider.allInstances.isNotEmpty) ...[
          SizedBox(height: 10.h),
          _CloudOverviewMetrics(
            readyCount: readyCloudNodes.length,
            pendingCount: pendingCloudNodes,
            selectedNodeLabel: selectedCloudProfileName,
            selectedNodeHint: _selectedNodeHint(
              l10n: l10n,
              selectedNodeLabel: selectedCloudProfileName,
              readyCount: readyCloudNodes.length,
              pendingCount: pendingCloudNodes,
              providerName: cloudProvider.providerId.displayName,
            ),
          ),
        ],
        SizedBox(height: 10.h),
        if (cloudProvider.error != null && cloudProvider.allInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.error_outline,
            title: l10n.failedToLoad,
            message: cloudProvider.error!,
            actionLabel: l10n.retry,
            onAction: onRetryLoad,
            secondaryActionLabel: l10n.setApiKey,
            onSecondaryAction: onConfigureApiKey,
            accentColor: Colors.orange,
          )
        else if (cloudProvider.allInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.cloud_queue,
            title: l10n.noCloudNodesYet,
            message: l10n.deployFirstNodeHint,
            actionLabel: l10n.deployNode,
            onAction: onCreateCloudNode,
            secondaryActionLabel: l10n.importProfile,
            onSecondaryAction: onImportProfile,
            accentColor: const Color(0xFF1452CC),
          )
        else
          ...cloudProvider.allInstances.map(_buildCloudInstanceCard),
      ],
    );
  }

  Widget _buildCloudInstanceCard(CloudInstance instance) {
    final profileName = cloudProfileName(instance);
    final linkedProfile = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;
    final isSelected = profileProvider.activeProfile?.name == profileName;

    return NodesCloudInstanceCard(
      instance: instance,
      latencyCheck: cloudProvider.latencyCheckFor(instance.id),
      isLinked: linkedProfile != null,
      isSelected: isSelected,
      isConnected: vpnProvider.status == VpnStatus.connected,
      onViewDetails: () => onViewDetails(instance),
      onDelete: () => onDeleteCloudNode(instance),
      onUseNode: () => onUseCloudNode(instance),
      onTestLatency: () => onTestCloudNodeLatency(instance),
    );
  }
}

String _selectedNodeHint({
  required AppLocalizations l10n,
  required String selectedNodeLabel,
  required int readyCount,
  required int pendingCount,
  required String providerName,
}) {
  if (selectedNodeLabel != l10n.noNodeSelected) {
    return providerName;
  }
  if (readyCount > 0) {
    return l10n.tapConnectHint;
  }
  if (pendingCount > 0) {
    return l10n.waitingForCredentials;
  }
  return l10n.noNodeSelectedHint;
}

class _CloudOverviewMetrics extends StatelessWidget {
  const _CloudOverviewMetrics({
    required this.readyCount,
    required this.pendingCount,
    required this.selectedNodeLabel,
    required this.selectedNodeHint,
  });

  final int readyCount;
  final int pendingCount;
  final String selectedNodeLabel;
  final String selectedNodeHint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8.w,
          runSpacing: 8.h,
          children: [
            _OverviewStatPill(
              icon: Icons.check_circle_outline,
              label: l10n.active,
              value: '$readyCount',
              color: const Color(0xFF0E9F6E),
            ),
            _OverviewStatPill(
              icon: Icons.hourglass_bottom,
              label: l10n.provisioning,
              value: '$pendingCount',
              color: const Color(0xFFF59E0B),
            ),
          ],
        ),
        SizedBox(height: 8.h),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
          decoration: BoxDecoration(
            color: const Color(0xFF1452CC).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(
              color: const Color(0xFF1452CC).withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34.w,
                height: 34.w,
                decoration: BoxDecoration(
                  color: const Color(0xFF1452CC).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: const Icon(
                  Icons.route_outlined,
                  size: 18,
                  color: Color(0xFF1452CC),
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.activeNode,
                      style: TextStyle(
                        fontSize: 11.sp,
                        color: Colors.grey[700],
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      selectedNodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      selectedNodeHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.sp,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CloudToolbar extends StatelessWidget {
  const _CloudToolbar({
    required this.selected,
    required this.onSelected,
    required this.onCreateCloudNode,
    required this.onTestAllCloudNodesLatency,
    required this.showCreateCloudNodeAction,
    required this.showBenchmarkAction,
  });

  final CloudProviderId selected;
  final ValueChanged<CloudProviderId> onSelected;
  final VoidCallback onCreateCloudNode;
  final VoidCallback onTestAllCloudNodesLatency;
  final bool showCreateCloudNodeAction;
  final bool showBenchmarkAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Wrap(
        spacing: 8.w,
        runSpacing: 8.h,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.cloudProvider,
            style: TextStyle(
              fontSize: 12.sp,
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
            ),
          ),
          ...CloudProviderId.values.map(
            (providerId) => ChoiceChip(
              label: Text(providerId.displayName),
              selected: providerId == selected,
              onSelected: (_) => onSelected(providerId),
            ),
          ),
          if (showCreateCloudNodeAction)
            FilledButton.icon(
              onPressed: onCreateCloudNode,
              icon: const Icon(Icons.add_circle_outline),
              label: Text(l10n.deployNode),
            ),
          if (showBenchmarkAction)
            OutlinedButton.icon(
              onPressed: onTestAllCloudNodesLatency,
              icon: const Icon(Icons.speed),
              label: Text(l10n.benchmarkAll),
            ),
        ],
      ),
    );
  }
}

class _OverviewStatPill extends StatelessWidget {
  const _OverviewStatPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16.sp, color: color),
          SizedBox(width: 8.w),
          Text(
            value,
            style: TextStyle(
              fontSize: 13.sp,
              fontWeight: FontWeight.bold,
              color: Colors.grey[900],
            ),
          ),
          SizedBox(width: 6.w),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.sp,
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }
}
