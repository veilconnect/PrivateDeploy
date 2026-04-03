import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_action_feedback.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialogs.dart';

Future<void> useCloudNodeAndConnect({
  required BuildContext context,
  required CloudInstance instance,
  required CloudProvider cloudProvider,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
}) async {
  final config = cloudProvider.generateNodeConfig(instance);
  if (config == null) {
    showNodesActionSnackBar(
      context,
      message: 'Node is not ready yet',
      backgroundColor: Colors.orange,
    );
    return;
  }

  final profileName = cloudProfileName(instance);
  final existing = profileProvider.profiles
      .where((profile) => profile.name == profileName)
      .firstOrNull;

  var success = true;
  if (existing == null) {
    success = await profileProvider.createProfile(
      name: profileName,
      content: config,
      allowReservedPrefix: true,
    );
    final created = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;
    if (success && created != null) {
      success = await profileProvider.activateProfile(created.id);
    }
  } else {
    success = await profileProvider.saveProfileContent(existing.id, config);
    if (success) {
      success = await profileProvider.activateProfile(existing.id);
    }
  }

  if (!context.mounted) {
    return;
  }

  if (!success) {
    showNodesActionSnackBar(
      context,
      message: profileProvider.error ?? 'Failed to activate node',
      backgroundColor: Colors.red,
    );
    return;
  }

  await connectSelectedProfile(
    context: context,
    vpnProvider: vpnProvider,
    profileProvider: profileProvider,
    cloudProvider: cloudProvider,
    onUseCloudNode: (selectedInstance) => useCloudNodeAndConnect(
      context: context,
      instance: selectedInstance,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    ),
    successMessage: 'Node is ready and connected',
  );
}

Future<void> activateProfileAndConnect({
  required BuildContext context,
  required Profile profile,
  required ProfileProvider profileProvider,
  required CloudProvider cloudProvider,
  required VpnProvider vpnProvider,
}) async {
  final success = await profileProvider.activateProfile(profile.id);
  if (!context.mounted) {
    return;
  }

  if (!success) {
    showNodesActionSnackBar(
      context,
      message: profileProvider.error ?? 'Failed to activate',
      backgroundColor: Colors.red,
    );
    return;
  }

  await connectSelectedProfile(
    context: context,
    vpnProvider: vpnProvider,
    profileProvider: profileProvider,
    cloudProvider: cloudProvider,
    onUseCloudNode: (instance) => useCloudNodeAndConnect(
      context: context,
      instance: instance,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    ),
    successMessage: 'Profile activated and connected',
  );
}

Future<void> handleNodesConnect({
  required BuildContext context,
  required VpnProvider vpnProvider,
  required ProfileProvider profileProvider,
  required CloudProvider cloudProvider,
  required Future<void> Function(CloudInstance instance) onUseCloudNode,
}) async {
  await connectSelectedProfile(
    context: context,
    vpnProvider: vpnProvider,
    profileProvider: profileProvider,
    cloudProvider: cloudProvider,
    onUseCloudNode: onUseCloudNode,
    autoSelectFastestCloudNode: true,
    successMessage: 'VPN connected successfully',
  );
}

Future<void> handleNodesDisconnect({
  required BuildContext context,
  required VpnProvider vpnProvider,
}) async {
  final success = await vpnProvider.disconnect();
  if (!context.mounted) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: success
        ? 'VPN disconnected successfully'
        : vpnProvider.error ?? 'Failed to disconnect VPN',
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

Future<void> handleNodesRestart({
  required BuildContext context,
  required VpnProvider vpnProvider,
  required ProfileProvider profileProvider,
  required CloudProvider cloudProvider,
  required Future<void> Function(CloudInstance instance) onUseCloudNode,
}) async {
  await connectSelectedProfile(
    context: context,
    vpnProvider: vpnProvider,
    profileProvider: profileProvider,
    cloudProvider: cloudProvider,
    onUseCloudNode: onUseCloudNode,
    forceReconnect: true,
    successMessage: 'VPN restarted successfully',
  );
}

Future<void> connectSelectedProfile({
  required BuildContext context,
  required VpnProvider vpnProvider,
  required ProfileProvider profileProvider,
  required CloudProvider cloudProvider,
  required Future<void> Function(CloudInstance instance) onUseCloudNode,
  required String successMessage,
  bool forceReconnect = false,
  bool autoSelectFastestCloudNode = false,
}) async {
  if (vpnProvider.isLoading ||
      vpnProvider.status == VpnStatus.connecting ||
      vpnProvider.status == VpnStatus.disconnecting) {
    showNodesActionSnackBar(
      context,
      message: 'VPN is busy, please wait a moment',
      backgroundColor: Colors.orange,
    );
    return;
  }

  final activeProfile = profileProvider.activeProfile;
  final readyCloudNodes = connectableCloudInstances(cloudProvider);
  if (autoSelectFastestCloudNode &&
      (activeProfile == null || isCloudManagedProfile(activeProfile))) {
    final usedFastestNode = await _useFastestReadyCloudNode(
      context: context,
      cloudProvider: cloudProvider,
      readyCloudNodes: readyCloudNodes,
      onUseCloudNode: onUseCloudNode,
    );
    if (usedFastestNode) {
      return;
    }
  }

  final routingSettings =
      context.read<AppSettingsProvider>().vpnRoutingSettings;
  final configJson = profileProvider.getActiveConfigJson(
    routingSettings: routingSettings,
  );
  if (configJson == null || configJson.isEmpty) {
    if (readyCloudNodes.length == 1) {
      await onUseCloudNode(readyCloudNodes.first);
      return;
    }
    if (readyCloudNodes.length > 1) {
      final selectedNode = await showNodesCloudNodePickerSheet(
        context,
        readyCloudNodes,
      );
      if (selectedNode != null && context.mounted) {
        await onUseCloudNode(selectedNode);
      }
      return;
    }

    showNodesActionSnackBar(
      context,
      message: cloudProvider.instances.isNotEmpty
          ? 'These cloud nodes are visible, but this device does not have their connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.'
          : 'No ready node selected yet. Choose a cloud node below or create/import a profile first.',
      backgroundColor: Colors.orange,
    );
    return;
  }

  final configError = validateSingboxConfig(configJson);
  if (configError != null) {
    showNodesActionSnackBar(
      context,
      message: configError,
      backgroundColor: Colors.red,
    );
    return;
  }

  if (vpnProvider.status == VpnStatus.connected) {
    final disconnected = await vpnProvider.disconnect();
    if (!disconnected) {
      if (context.mounted) {
        showNodesActionSnackBar(
          context,
          message: vpnProvider.error ?? 'Failed to switch active VPN node',
          backgroundColor: Colors.red,
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
    }
    if (!forceReconnect) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  final connected = await vpnProvider.connect(
    configJson: configJson,
    profileName: activeProfile?.name,
    stabilityCheckDuration: const Duration(seconds: 6),
    statusPollInterval: const Duration(milliseconds: 500),
  );
  if (!context.mounted) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: connected
        ? successMessage
        : vpnProvider.error ?? 'Failed to connect VPN',
    backgroundColor: connected ? Colors.green : Colors.red,
  );
}

Future<bool> _useFastestReadyCloudNode({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required List<CloudInstance> readyCloudNodes,
  required Future<void> Function(CloudInstance instance) onUseCloudNode,
}) async {
  if (readyCloudNodes.isEmpty) {
    return false;
  }

  if (readyCloudNodes.length == 1) {
    await onUseCloudNode(readyCloudNodes.first);
    return true;
  }

  final cachedSelection = cloudProvider.cachedFastestConnectableInstance(
    maxAge: CloudProvider.connectSelectionReuseMaxAge,
  );
  if (cachedSelection.hasSelection) {
    final cachedLatencyMs = cachedSelection.latencyCheck?.latencyMs;
    final cachedEndpoint = cachedSelection.latencyCheck?.endpointLabel;
    final cachedThroughput = cachedSelection.latencyCheck?.throughputMbps;
    final metricSuffix = cachedThroughput != null && cachedThroughput > 0
        ? ' (${cachedThroughput >= 100 ? cachedThroughput.toStringAsFixed(0) : cachedThroughput >= 10 ? cachedThroughput.toStringAsFixed(1) : cachedThroughput.toStringAsFixed(2)} Mbps)'
        : cachedLatencyMs != null
            ? ' (${cachedLatencyMs} ms)'
            : '';
    final endpointSuffix = cachedEndpoint != null && cachedEndpoint.isNotEmpty
        ? ' via $cachedEndpoint'
        : '';
    showNodesActionSnackBar(
      context,
      message:
          'Using recent fastest node: ${cachedSelection.instance!.label}$metricSuffix$endpointSuffix. Refreshing ranking in background...',
      backgroundColor: Colors.blue,
      replaceCurrent: true,
    );
    await onUseCloudNode(cachedSelection.instance!);
    unawaited(
      cloudProvider.selectFastestConnectableInstance(forceRefresh: true),
    );
    return true;
  }

  showNodesActionSnackBar(
    context,
    message: 'Quick-testing ready nodes and selecting the fastest one...',
    backgroundColor: Colors.blue,
    replaceCurrent: true,
  );

  final selection = await cloudProvider.selectFastestConnectableInstance(
    forceRefresh: true,
  );
  if (!context.mounted) {
    return true;
  }

  final selectedInstance = selection.instance ?? readyCloudNodes.firstOrNull;
  if (selectedInstance == null) {
    showNodesActionSnackBar(
      context,
      message: selection.error ?? 'No ready cloud node is available yet',
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
    return true;
  }

  if (!selection.hasSelection) {
    showNodesActionSnackBar(
      context,
      message:
          '${selection.error ?? 'Latency test was unavailable.'} Using ${selectedInstance.label} instead.',
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
  }

  await onUseCloudNode(selectedInstance);
  return true;
}
