import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
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
      message: AppLocalizations.of(context)!.nodeNotReady,
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
      message: profileProvider.error ?? AppLocalizations.of(context)!.failedToActivateNode,
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
    successMessage: AppLocalizations.of(context)!.nodeReadyConnected,
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
      message: profileProvider.error ?? AppLocalizations.of(context)!.failedToActivate,
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
    successMessage: AppLocalizations.of(context)!.profileActivatedConnected,
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
    successMessage: AppLocalizations.of(context)!.vpnConnectedSuccess,
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

  final l10nDisconnect = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nDisconnect.vpnDisconnectedSuccess
        : vpnProvider.error ?? l10nDisconnect.failedToDisconnectVpn,
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
    successMessage: AppLocalizations.of(context)!.vpnRestartedSuccess,
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
      message: AppLocalizations.of(context)!.vpnBusyWait,
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

    final l10nHint = AppLocalizations.of(context)!;
    showNodesActionSnackBar(
      context,
      message: cloudProvider.instances.isNotEmpty
          ? l10nHint.noCredentialsHint
          : l10nHint.noNodeSelectedHint,
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
      message: AppLocalizations.of(context)!.usingFastestNode(
        cachedSelection.instance!.label,
        metricSuffix,
        endpointSuffix,
      ),
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
    message: AppLocalizations.of(context)!.quickTestingNodes,
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
      message: selection.error ?? AppLocalizations.of(context)!.noReadyCloudNode,
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
    return true;
  }

  if (!selection.hasSelection) {
    final l10nFallback = AppLocalizations.of(context)!;
    showNodesActionSnackBar(
      context,
      message: l10nFallback.usingNodeInstead(
        selection.error ?? l10nFallback.latencyTestUnavailable,
        selectedInstance.label,
      ),
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
  }

  await onUseCloudNode(selectedInstance);
  return true;
}
