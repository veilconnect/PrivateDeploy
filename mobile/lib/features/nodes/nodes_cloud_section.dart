import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

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
    final readyCloudNodes = connectableCloudInstances(cloudProvider);
    if (!cloudProvider.hasApiKey) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NodesSectionHeader(
            title: 'Cloud Nodes',
            subtitle: 'Deploy and use nodes from your cloud account',
            count: 0,
          ),
          SizedBox(height: 8.h),
          NodesInlineInfoCard(
            icon: Icons.cloud_off,
            title: 'Cloud access not configured',
            message:
                'Save your Vultr API key to deploy nodes directly from this device.',
            actionLabel: 'Set API Key',
            onAction: onConfigureApiKey,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodesSectionHeader(
          title: 'Cloud Nodes',
          subtitle: 'Deploy, sync, and use cloud-backed nodes',
          count: cloudProvider.instances.length,
        ),
        if (readyCloudNodes.length > 1) ...[
          SizedBox(height: 8.h),
          Wrap(
            spacing: 10.w,
            runSpacing: 8.h,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onTestAllCloudNodesLatency,
                icon: const Icon(Icons.speed),
                label: const Text('Test All Nodes'),
              ),
              Text(
                'Measures TCP handshake latency across available protocols.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
        SizedBox(height: 8.h),
        if (cloudProvider.error != null && cloudProvider.instances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.error_outline,
            title: 'Failed to load cloud nodes',
            message: cloudProvider.error!,
            actionLabel: 'Retry',
            onAction: onRetryLoad,
          )
        else if (cloudProvider.instances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.cloud_queue,
            title: 'No cloud nodes yet',
            message:
                'Deploy your first node here. Once it becomes active, use it directly from this page.',
            actionLabel: 'Deploy Node',
            onAction: onCreateCloudNode,
          )
        else
          ...cloudProvider.instances.map(_buildCloudInstanceCard),
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
