import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_node_config_builder.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_action_feedback.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_widgets.dart';

class NodesCloudSection extends StatelessWidget {
  final CloudProvider cloudProvider;
  final ProfileProvider profileProvider;
  final VpnProvider vpnProvider;
  final bool suppressSetupActions;
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
    this.suppressSetupActions = false,
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
    final visibleCloudInstances = cloudProvider.allInstances
        .where(
            (instance) => _matchesProvider(instance, cloudProvider.providerId))
        .toList();
    final readyCloudNodes = visibleCloudInstances
        .where((instance) => cloudProvider.generateNodeConfig(instance) != null)
        .toList();
    final orderedCloudInstances = List<CloudInstance>.from(
      visibleCloudInstances,
    )..sort(
        (a, b) => _compareCloudInstances(
          a: a,
          b: b,
          activeProfileName: profileProvider.activeProfile?.name,
          profiles: profileProvider.profiles,
          cloudProvider: cloudProvider,
        ),
      );
    final pendingCloudNodes =
        visibleCloudInstances.length - readyCloudNodes.length;
    final accessHint = cloudProvider.providerId == CloudProviderId.ssh
        ? l10n.setSshAccessHint
        : l10n.setCloudProviderApiKeyHint;
    final headerSubtitle =
        cloudProvider.hasApiKey || cloudProvider.hasStoredApiKey
            ? [
                cloudProvider.providerId.displayName,
                if (visibleCloudInstances.isNotEmpty)
                  '${readyCloudNodes.length} ${l10n.active} · $pendingCloudNodes ${l10n.provisioning}',
              ].join(' · ')
            : null;
    if (!cloudProvider.hasApiKey &&
        cloudProvider.hasStoredApiKey &&
        cloudProvider.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NodesSectionHeader(
            title: l10n.cloudNodes,
            subtitle: headerSubtitle,
            count: visibleCloudInstances.length,
          ),
          SizedBox(height: 10.h),
          _CloudToolbar(
            selected: cloudProvider.providerId,
            onSelected: (providerId) {
              unawaited(onManageProviderChanged(providerId));
            },
            onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
            showBenchmarkAction: readyCloudNodes.length > 1,
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
          if (visibleCloudInstances.isNotEmpty) ...[
            SizedBox(height: 10.h),
            ...orderedCloudInstances.map(
              (instance) => _buildCloudInstanceCard(context, instance),
            ),
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
            onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
            showBenchmarkAction: false,
          ),
          SizedBox(height: 8.h),
          NodesInlineInfoCard(
            icon: Icons.cloud_off,
            title: l10n.cloudAccessNotConfigured,
            message: accessHint,
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
          count: visibleCloudInstances.length,
        ),
        SizedBox(height: 10.h),
        _CloudToolbar(
          selected: cloudProvider.providerId,
          onSelected: (providerId) {
            unawaited(onManageProviderChanged(providerId));
          },
          onTestAllCloudNodesLatency: onTestAllCloudNodesLatency,
          showBenchmarkAction: readyCloudNodes.length > 1,
        ),
        SizedBox(height: 10.h),
        if (cloudProvider.error != null && visibleCloudInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.error_outline,
            title: l10n.failedToLoad,
            message: cloudProvider.error!,
            actionLabel: l10n.retry,
            onAction: onRetryLoad,
            accentColor: Colors.orange,
          )
        else if (visibleCloudInstances.isEmpty)
          NodesInlineInfoCard(
            icon: Icons.cloud_queue,
            title: l10n.noCloudNodesYet,
            message: l10n.deployFirstNodeHint,
            accentColor: const Color(0xFF1452CC),
          )
        else
          ...orderedCloudInstances.map(
            (instance) => _buildCloudInstanceCard(context, instance),
          ),
      ],
    );
  }

  Widget _buildCloudInstanceCard(BuildContext context, CloudInstance instance) {
    final profileName = cloudProfileName(instance);
    final linkedProfile = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;
    final isSelected = profileProvider.activeProfile?.name == profileName;
    final preferredEndpointLabel =
        cloudProvider.preferredEndpointLabelFor(instance);

    return NodesCloudInstanceCard(
      instance: instance,
      latencyCheck: cloudProvider.latencyCheckFor(instance.id),
      activeEndpointLabel: isSelected
          ? activeCloudNodeEndpointLabel(profileProvider.activeProfile?.content)
          : null,
      preferredEndpointLabel: preferredEndpointLabel,
      availableEndpointLabels: cloudProvider.availableEndpointLabelsFor(
        instance,
      ),
      isLinked: linkedProfile != null,
      isSelected: isSelected,
      isConnected: vpnProvider.status == VpnStatus.connected,
      onViewDetails: () => onViewDetails(instance),
      onDelete: () => onDeleteCloudNode(instance),
      onUseNode: () => onUseCloudNode(instance),
      onTestLatency: () => onTestCloudNodeLatency(instance),
      onChooseEndpoint: () => _chooseEndpointForInstance(
        context,
        instance,
        isSelected: isSelected,
        isConnected: vpnProvider.status == VpnStatus.connected,
      ),
    );
  }

  Future<void> _chooseEndpointForInstance(
    BuildContext context,
    CloudInstance instance, {
    required bool isSelected,
    required bool isConnected,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final availableLabels = cloudProvider.availableEndpointLabelsFor(instance);
    if (availableLabels.isEmpty) {
      return;
    }

    final currentPreference = cloudProvider.preferredEndpointLabelFor(instance);
    final selectedValue = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final sheetL10n = AppLocalizations.of(sheetContext)!;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(24.w, 8.h, 24.w, 8.h),
                child: Text(
                  sheetL10n.chooseProtocolForNode(instance.label),
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              ListTile(
                title: Text(sheetL10n.automatic),
                subtitle: Text(sheetL10n.protocolAutomaticHint),
                trailing: currentPreference == null
                    ? const Icon(Icons.check, color: Color(0xFF1452CC))
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(''),
              ),
              ...availableLabels.map(
                (label) => ListTile(
                  title: Text(label),
                  trailing: currentPreference == label
                      ? const Icon(Icons.check, color: Color(0xFF1452CC))
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(label),
                ),
              ),
              SizedBox(height: 8.h),
            ],
          ),
        );
      },
    );

    if (selectedValue == null) {
      return;
    }

    final nextPreference = selectedValue.trim().isEmpty ? null : selectedValue;
    if (nextPreference == currentPreference) {
      return;
    }

    await cloudProvider.setPreferredEndpointLabel(instance, nextPreference);
    if (!context.mounted) {
      return;
    }

    if (isSelected && isConnected) {
      onUseCloudNode(instance);
      return;
    }

    final targetLabel = nextPreference ?? l10n.automatic;
    showNodesActionSnackBar(
      context,
      message: l10n.protocolSaved(instance.label, targetLabel),
      backgroundColor: Colors.green,
    );
  }
}

bool _matchesProvider(CloudInstance instance, CloudProviderId providerId) {
  return CloudProviderId.tryParse(instance.provider) == providerId;
}

int _compareCloudInstances({
  required CloudInstance a,
  required CloudInstance b,
  required String? activeProfileName,
  required List<Profile> profiles,
  required CloudProvider cloudProvider,
}) {
  final aProfileName = cloudProfileName(a);
  final bProfileName = cloudProfileName(b);
  final aSelected = activeProfileName == aProfileName;
  final bSelected = activeProfileName == bProfileName;
  if (aSelected != bSelected) {
    return aSelected ? -1 : 1;
  }

  final aReady = a.isActive && a.hasIp && a.nodeInfo != null;
  final bReady = b.isActive && b.hasIp && b.nodeInfo != null;
  if (aReady != bReady) {
    return aReady ? -1 : 1;
  }

  final aLinked = profiles.any((profile) => profile.name == aProfileName);
  final bLinked = profiles.any((profile) => profile.name == bProfileName);
  if (aLinked != bLinked) {
    return aLinked ? -1 : 1;
  }

  final latencyPriority = _compareLatencyPriority(
    cloudProvider.latencyCheckFor(a.id),
    cloudProvider.latencyCheckFor(b.id),
  );
  if (latencyPriority != 0) {
    return latencyPriority;
  }

  final createdAtPriority = (b.createdAt ?? DateTime(0)).compareTo(
    a.createdAt ?? DateTime(0),
  );
  if (createdAtPriority != 0) {
    return createdAtPriority;
  }

  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}

int _compareLatencyPriority(CloudLatencyCheck? a, CloudLatencyCheck? b) {
  final aHasUsableResult = _hasUsableLatencyResult(a);
  final bHasUsableResult = _hasUsableLatencyResult(b);
  if (aHasUsableResult != bHasUsableResult) {
    return aHasUsableResult ? -1 : 1;
  }
  if (!aHasUsableResult) {
    return 0;
  }

  final updatedAtPriority = (b!.updatedAt ?? DateTime(0)).compareTo(
    a!.updatedAt ?? DateTime(0),
  );
  if (updatedAtPriority != 0) {
    return updatedAtPriority;
  }

  if (a.isBenchmark != b.isBenchmark) {
    return a.isBenchmark ? -1 : 1;
  }

  final throughputPriority =
      (b.throughputMbps ?? -1).compareTo(a.throughputMbps ?? -1);
  if (throughputPriority != 0) {
    return throughputPriority;
  }

  return (a.latencyMs ?? (1 << 30)).compareTo(b.latencyMs ?? (1 << 30));
}

bool _hasUsableLatencyResult(CloudLatencyCheck? check) {
  if (check == null || check.isTesting || check.error != null) {
    return false;
  }
  return check.latencyMs != null || check.hasThroughput;
}

class _CloudToolbar extends StatelessWidget {
  const _CloudToolbar({
    required this.selected,
    required this.onSelected,
    required this.onTestAllCloudNodesLatency,
    required this.showBenchmarkAction,
  });

  final CloudProviderId selected;
  final ValueChanged<CloudProviderId> onSelected;
  final VoidCallback onTestAllCloudNodesLatency;
  final bool showBenchmarkAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final providerId in CloudProviderId.values) ...[
                  ChoiceChip(
                    label: Text(providerId.displayName),
                    selected: providerId == selected,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    labelPadding: EdgeInsets.symmetric(horizontal: 6.w),
                    onSelected: (_) => onSelected(providerId),
                  ),
                  SizedBox(width: 8.w),
                ],
              ],
            ),
          ),
        ),
        if (showBenchmarkAction)
          PopupMenuButton<String>(
            tooltip: l10n.more,
            icon: const Icon(Icons.more_horiz),
            style: IconButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelected: (value) {
              if (value == 'benchmark') {
                onTestAllCloudNodesLatency();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'benchmark',
                child: Row(
                  children: [
                    const Icon(Icons.speed, size: 18),
                    const SizedBox(width: 10),
                    Text(l10n.benchmarkAll),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}
