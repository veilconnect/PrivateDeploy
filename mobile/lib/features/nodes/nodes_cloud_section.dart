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
    final pendingCloudNodes = cloudProvider.allInstances.length - readyCloudNodes.length;
    final selectedCloudProfile = profileProvider.activeProfile;
    final selectedCloudProfileName =
        selectedCloudProfile != null && isCloudManagedProfile(selectedCloudProfile)
            ? selectedCloudProfile.name
            : l10n.noNodeSelected;
    final headerSubtitle =
        '${cloudProvider.providerId.displayName} · ${readyCloudNodes.length}/${cloudProvider.allInstances.length}';
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
          _ProviderSwitchRow(
            selected: cloudProvider.providerId,
            onSelected: (providerId) {
              unawaited(onManageProviderChanged(providerId));
            },
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
            accentColor: Colors.orange,
          ),
          if (cloudProvider.allInstances.isNotEmpty) ...[
            SizedBox(height: 10.h),
            _SectionActionsRow(
              readyCloudNodeCount: readyCloudNodes.length,
              onCreateCloudNode: onCreateCloudNode,
              onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
            ),
            SizedBox(height: 8.h),
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
          _ProviderSwitchRow(
            selected: cloudProvider.providerId,
            onSelected: (providerId) {
              unawaited(onManageProviderChanged(providerId));
            },
          ),
          SizedBox(height: 8.h),
          NodesInlineInfoCard(
            icon: Icons.cloud_off,
            title: l10n.cloudAccessNotConfigured,
            message: l10n.setCloudProviderApiKeyHint(
                cloudProvider.providerId.displayName),
            actionLabel: l10n.setApiKey,
            onAction: onConfigureApiKey,
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
        _ProviderSwitchRow(
          selected: cloudProvider.providerId,
          onSelected: (providerId) {
            unawaited(onManageProviderChanged(providerId));
          },
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
        _SectionActionsRow(
          readyCloudNodeCount: readyCloudNodes.length,
          onCreateCloudNode: onCreateCloudNode,
          onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
        ),
        SizedBox(height: 10.h),
        if (cloudProvider.error != null && cloudProvider.allInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.error_outline,
            title: l10n.failedToLoad,
            message: cloudProvider.error!,
            actionLabel: l10n.retry,
            onAction: onRetryLoad,
            accentColor: Colors.orange,
          )
        else if (cloudProvider.allInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.cloud_queue,
            title: l10n.noCloudNodesYet,
            message: l10n.deployFirstNodeHint,
            actionLabel: l10n.deployNode,
            onAction: onCreateCloudNode,
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

class _SectionActionsRow extends StatelessWidget {
  const _SectionActionsRow({
    required this.readyCloudNodeCount,
    required this.onCreateCloudNode,
    required this.onTestAllCloudNodesLatency,
  });

  final int readyCloudNodeCount;
  final VoidCallback onCreateCloudNode;
  final VoidCallback onTestAllCloudNodesLatency;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 8.w,
      runSpacing: 8.h,
      children: [
        FilledButton.icon(
          onPressed: onCreateCloudNode,
          icon: const Icon(Icons.add_circle_outline),
          label: Text(l10n.deployNode),
        ),
        if (readyCloudNodeCount > 1)
          OutlinedButton.icon(
            onPressed: onTestAllCloudNodesLatency,
            icon: const Icon(Icons.speed),
            label: Text(l10n.benchmarkAll),
          ),
      ],
    );
  }
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final halfWidth = (constraints.maxWidth - 10.w) / 2;
        return Wrap(
          spacing: 10.w,
          runSpacing: 10.h,
          children: [
            SizedBox(
              width: halfWidth,
              child: NodesMetricTile(
                icon: Icons.check_circle_outline,
                label: l10n.active,
                value: '$readyCount',
                hint: l10n.cloudNodes,
                color: const Color(0xFF0E9F6E),
              ),
            ),
            SizedBox(
              width: halfWidth,
              child: NodesMetricTile(
                icon: Icons.hourglass_bottom,
                label: l10n.provisioning,
                value: '$pendingCount',
                hint: l10n.refresh,
                color: const Color(0xFFF59E0B),
              ),
            ),
            SizedBox(
              width: constraints.maxWidth,
              child: NodesMetricTile(
                icon: Icons.route_outlined,
                label: l10n.activeNode,
                value: selectedNodeLabel,
                hint: selectedNodeHint,
                color: const Color(0xFF1452CC),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProviderSwitchRow extends StatelessWidget {
  const _ProviderSwitchRow({
    required this.selected,
    required this.onSelected,
  });

  final CloudProviderId selected;
  final ValueChanged<CloudProviderId> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
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
      ],
    );
  }
}
