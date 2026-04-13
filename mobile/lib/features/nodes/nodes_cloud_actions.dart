import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_throughput_probe.dart';
import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_action_feedback.dart';
import 'nodes_dialogs.dart';

bool isCloudManagedProfile(Profile profile) {
  return ProfileProvider.isCloudManagedProfileName(profile.name);
}

String cloudProfileName(CloudInstance instance) {
  return '${ProfileProvider.cloudManagedProfilePrefix}${instance.label}';
}

List<CloudInstance> connectableCloudInstances(CloudProvider cloudProvider) {
  return cloudProvider.instances
      .where(
        (instance) =>
            instance.isActive && instance.hasIp && instance.nodeInfo != null,
      )
      .toList();
}

Future<void> confirmDeleteCloudNode({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  required CloudInstance instance,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showNodesDeleteConfirmationDialog(
    context: context,
    title: l10n.deleteNodeTitle,
    message: l10n.deleteNodeConfirm(instance.label),
  );
  if (!confirmed) {
    return;
  }

  final profileName = cloudProfileName(instance);
  final linkedProfile = profileProvider.getProfileByName(profileName);
  final shouldDisconnect = linkedProfile != null &&
      profileProvider.activeProfile?.id == linkedProfile.id &&
      vpnProvider.status != VpnStatus.disconnected;

  final success = await cloudProvider.deleteInstance(instance.id);
  var disconnectSuccess = true;
  var profileCleanupSuccess = true;

  if (success && shouldDisconnect) {
    disconnectSuccess = await vpnProvider.disconnect();
  }

  if (success) {
    profileCleanupSuccess = await profileProvider.deleteProfileByName(
      profileName,
    );
  }

  if (!context.mounted) {
    return;
  }

  final l10nFeedback = AppLocalizations.of(context)!;
  final operationSucceeded =
      success && disconnectSuccess && profileCleanupSuccess;
  final message = success
      ? operationSucceeded
          ? l10nFeedback.nodeDeleted
          : l10nFeedback.nodeDeletedCleanupNeeded
      : cloudProvider.error ?? l10nFeedback.failedToDelete;
  showNodesActionSnackBar(
    context,
    message: message,
    backgroundColor: operationSucceeded
        ? Colors.green
        : success
            ? Colors.orange
            : Colors.red,
  );
}

Future<void> showCloudApiKeyFlow({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required Future<void> Function() onSaved,
}) async {
  final success = await showNodesCloudApiKeyDialog(
    context: context,
    initialValue: cloudProvider.apiKey ?? '',
    onVerifyAndSave: (apiKey) async {
      final saved = await cloudProvider.setApiKey(apiKey);
      return saved ? null : cloudProvider.error ?? AppLocalizations.of(context)!.failedToSaveApiKey;
    },
  );
  if (!success || !context.mounted) {
    return;
  }

  final l10nApiKey = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: l10nApiKey.apiKeyVerifiedLoadingNodes,
    backgroundColor: Colors.green,
  );

  await onSaved();
  if (!context.mounted) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: AppLocalizations.of(context)!.apiKeySavedNodesLoaded,
    backgroundColor: Colors.green,
    replaceCurrent: true,
  );
}

Future<void> showCreateCloudNodeFlow({
  required BuildContext context,
  required CloudProvider cloudProvider,
}) async {
  if (cloudProvider.regions.isEmpty && !cloudProvider.isLoadingRegions) {
    unawaited(cloudProvider.loadRegions());
  }
  if (cloudProvider.plans.isEmpty && !cloudProvider.isLoadingPlans) {
    unawaited(cloudProvider.loadPlans());
  }

  final request = await showNodesCreateCloudDialog(context);
  if (request == null || !context.mounted) {
    return;
  }

  final success = await cloudProvider.createInstance(
    region: request.region,
    plan: request.plan,
    label: request.label,
  );
  if (!context.mounted) {
    return;
  }

  final l10nDeploy = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nDeploy.nodeDeploying
        : cloudProvider.error ?? l10nDeploy.failedToCreate,
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

Future<void> testCloudNodeLatency({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required CloudInstance instance,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  Future<CloudThroughputSample> Function()? throughputProbe,
}) async {
  // Phase 1: TCP latency probe (benchmark mode for multiple samples).
  final latencyResult = await cloudProvider.testInstanceLatency(
    instance,
    mode: CloudProbeMode.benchmark,
  );

  // Phase 2: throughput test via a real VPN tunnel.
  final config = cloudProvider.generateNodeConfig(instance);
  if (config == null) {
    final updated = latencyResult.copyWith(
      error: latencyResult.error ?? AppLocalizations.of(context)!.nodeNotReadyForSpeedTest,
    );
    cloudProvider.saveLatencyCheck(instance.id, updated);
    if (context.mounted && updated.error != null) {
      showNodesActionSnackBar(
        context,
        message: updated.error!,
        backgroundColor: Colors.orange,
      );
    }
    return;
  }

  final previouslyConnected = vpnProvider.status == VpnStatus.connected;
  final previousProfileName = vpnProvider.activeProfile;
  final previousConfigJson = previouslyConnected
      ? profileProvider.getActiveConfigJson(
          routingSettings:
              context.read<AppSettingsProvider>().vpnRoutingSettings,
        )
      : null;

  if (previouslyConnected) {
    await vpnProvider.disconnect();
  }

  final benchmarkConfig = normalizeProfileConfigForCurrentPlatform(config);
  final connected = await vpnProvider.connect(
    configJson: benchmarkConfig,
    profileName: cloudProfileName(instance),
    stabilityCheckDuration: const Duration(seconds: 3),
    statusPollInterval: const Duration(milliseconds: 500),
  );

  var benchmarkResult = latencyResult;
  if (connected) {
    // Let the tunnel fully stabilize (DNS, routing) before probing.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final probe = throughputProbe ?? runCloudThroughputProbe;
    final throughputSample = await probe();
    benchmarkResult = benchmarkResult.copyWith(
      updatedAt: DateTime.now(),
      throughputMbps: throughputSample.speedMbps,
      throughputBytes: throughputSample.bytes,
      throughputElapsedMs: throughputSample.elapsedMs,
      error: throughputSample.hasSample
          ? benchmarkResult.error
          : throughputSample.error ?? benchmarkResult.error,
    );
    await vpnProvider.disconnect();
  } else {
    benchmarkResult = benchmarkResult.copyWith(
      error: vpnProvider.error ?? AppLocalizations.of(context)!.failedToConnectSpeedTestTunnel,
    );
  }

  cloudProvider.saveLatencyCheck(instance.id, benchmarkResult);

  // Restore previous VPN connection if one was active.
  if (previouslyConnected && previousConfigJson != null) {
    await vpnProvider.connect(
      configJson: previousConfigJson,
      profileName: previousProfileName,
      stabilityCheckDuration: const Duration(seconds: 1),
      statusPollInterval: const Duration(milliseconds: 250),
    );
  }

  if (context.mounted && benchmarkResult.error != null) {
    showNodesActionSnackBar(
      context,
      message: benchmarkResult.error!,
      backgroundColor: Colors.orange,
    );
  }
}

Future<void> testAllCloudNodesLatency({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  Future<CloudThroughputSample> Function()? throughputProbe,
}) async {
  final l10nBench = AppLocalizations.of(context)!;
  final readyNodes = connectableCloudInstances(cloudProvider);
  if (readyNodes.isEmpty) {
    showNodesActionSnackBar(
      context,
      message: l10nBench.noReadyNodeForTesting,
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
    return;
  }

  final previouslyConnected = vpnProvider.status == VpnStatus.connected;
  if (previouslyConnected) {
    final confirmed = await showNodesConfirmationDialog(
      context: context,
      title: l10nBench.benchmarkAllNodesTitle,
      message: l10nBench.benchmarkAllNodesConfirm,
      confirmLabel: l10nBench.startBenchmark,
      confirmColor: Colors.orange,
    );
    if (!confirmed) {
      return;
    }
  }

  final previousProfileName = vpnProvider.activeProfile;
  final previousConfigJson = previouslyConnected
      ? profileProvider.getActiveConfigJson(
          routingSettings:
              context.read<AppSettingsProvider>().vpnRoutingSettings,
        )
      : null;
  final runThroughputProbe = throughputProbe ?? runCloudThroughputProbe;
  var restoreFailed = false;

  showNodesActionSnackBar(
    context,
    message: l10nBench.benchmarkingNodes,
    backgroundColor: Colors.blue,
    replaceCurrent: true,
  );

  var selection = CloudFastestNodeSelection(
    error: l10nBench.noReadyNodeForTesting,
  );
  try {
    if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }

    for (var index = 0; index < readyNodes.length; index += 1) {
      final instance = readyNodes[index];
      if (context.mounted) {
        final l10nProgress = AppLocalizations.of(context)!;
        showNodesActionSnackBar(
          context,
          message: l10nProgress.benchmarkingNode(instance.label, index + 1, readyNodes.length),
          backgroundColor: Colors.blue,
          replaceCurrent: true,
        );
      }

      final latencyResult = await cloudProvider.testInstanceLatency(
        instance,
        mode: CloudProbeMode.benchmark,
      );
      var benchmarkResult = latencyResult;

      final config = cloudProvider.generateNodeConfig(instance);
      if (config == null) {
        benchmarkResult = benchmarkResult.copyWith(
          error: benchmarkResult.error ?? l10nBench.nodeNotReadyForBenchmark,
        );
        cloudProvider.saveLatencyCheck(instance.id, benchmarkResult);
        continue;
      }

      final benchmarkConfig = normalizeProfileConfigForCurrentPlatform(config);

      final connected = await vpnProvider.connect(
        configJson: benchmarkConfig,
        profileName: cloudProfileName(instance),
        stabilityCheckDuration: const Duration(seconds: 3),
        statusPollInterval: const Duration(milliseconds: 500),
      );

      if (!connected) {
        benchmarkResult = benchmarkResult.copyWith(
          error: vpnProvider.error ?? l10nBench.failedToConnectBenchmarkTunnel,
        );
        cloudProvider.saveLatencyCheck(instance.id, benchmarkResult);
        continue;
      }

      // Let the tunnel fully stabilize before probing throughput.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final throughputSample = await runThroughputProbe();
      benchmarkResult = benchmarkResult.copyWith(
        updatedAt: DateTime.now(),
        throughputMbps: throughputSample.speedMbps,
        throughputBytes: throughputSample.bytes,
        throughputElapsedMs: throughputSample.elapsedMs,
        error: throughputSample.hasSample
            ? benchmarkResult.error
            : throughputSample.error ?? benchmarkResult.error,
      );
      cloudProvider.saveLatencyCheck(instance.id, benchmarkResult);

      await vpnProvider.disconnect();
    }

    selection = cloudProvider.cachedFastestConnectableInstance(
      maxAge: CloudProvider.connectSelectionReuseMaxAge,
    );
  } finally {
    if (previouslyConnected && previousConfigJson != null) {
      final restored = await vpnProvider.connect(
        configJson: previousConfigJson,
        profileName: previousProfileName,
        stabilityCheckDuration: const Duration(seconds: 1),
        statusPollInterval: const Duration(milliseconds: 250),
      );
      restoreFailed = !restored;
    } else if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }
  }

  if (!context.mounted) {
    return;
  }
  final l10nResult = AppLocalizations.of(context)!;
  if (!selection.hasSelection) {
    showNodesActionSnackBar(
      context,
      message:
          selection.error ?? l10nResult.noReadyNodeForTesting,
      backgroundColor: Colors.orange,
      replaceCurrent: true,
    );
    return;
  }

  final latencyMs = selection.latencyCheck?.latencyMs;
  final throughputMbps = selection.latencyCheck?.throughputMbps;
  final endpoint = selection.latencyCheck?.endpointLabel;
  final throughputSuffix = throughputMbps != null && throughputMbps > 0
      ? ' (${throughputMbps >= 100 ? throughputMbps.toStringAsFixed(0) : throughputMbps >= 10 ? throughputMbps.toStringAsFixed(1) : throughputMbps.toStringAsFixed(2)} Mbps)'
      : '';
  final latencySuffix = latencyMs != null ? ' \u2022 ${l10nResult.msLatency(latencyMs)}' : '';
  final endpointSuffix =
      endpoint != null && endpoint.isNotEmpty ? ' via $endpoint' : '';
  final restoreSuffix =
      restoreFailed ? ' \u2022 ${l10nResult.restoreConnectionFailed}' : '';
  showNodesActionSnackBar(
    context,
    message:
        l10nResult.bestBenchmark(selection.instance!.label, throughputSuffix, '$endpointSuffix$latencySuffix$restoreSuffix'),
    backgroundColor: restoreFailed ? Colors.orange : Colors.green,
    replaceCurrent: true,
  );
}
