import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
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
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final readyCloudNodes = connectableCloudInstances(cloudProvider);
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
