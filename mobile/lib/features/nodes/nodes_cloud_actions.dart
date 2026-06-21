import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cdn/cdn_provider.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../cloud/cloud_throughput_probe.dart';
import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import '../vpn/vpn_status_messages.dart';
import '../settings/settings_api_key_dialog.dart';
import 'nodes_action_feedback.dart';
import 'nodes_dialogs.dart';
import 'nodes_vpn_session_restore.dart';

bool isCloudManagedProfile(Profile profile) {
  return ProfileProvider.isCloudManagedProfileName(profile.name);
}

String cloudProfileName(CloudInstance instance) {
  return '${ProfileProvider.cloudManagedProfilePrefix}${instance.label}';
}

List<CloudInstance> connectableCloudInstances(CloudProvider cloudProvider) {
  return cloudProvider.allInstances
      .where(
        (instance) =>
            !instance.missing &&
            instance.isActive &&
            cloudProvider.generateNodeConfig(instance) != null,
      )
      .toList();
}

bool isUsableSavedCloudProfile(Profile profile) {
  return isCloudManagedProfile(profile) &&
      (profile.content?.trim().isNotEmpty ?? false);
}

int availableCloudRouteCount({
  required List<CloudInstance> readyCloudNodes,
  required List<Profile> profiles,
  Profile? selectedProfile,
}) {
  final linkedReadyProfileNames = readyCloudNodes.map(cloudProfileName).toSet();
  final savedCloudProfileNames = <String>{
    for (final profile in profiles)
      if (isUsableSavedCloudProfile(profile) &&
          !linkedReadyProfileNames.contains(profile.name))
        profile.name,
  };

  if (selectedProfile != null &&
      isUsableSavedCloudProfile(selectedProfile) &&
      !linkedReadyProfileNames.contains(selectedProfile.name)) {
    savedCloudProfileNames.add(selectedProfile.name);
  }

  return readyCloudNodes.length + savedCloudProfileNames.length;
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

  // Capture before any await so we don't touch context across async gaps.
  final cdnProvider = context.read<CdnProvider>();
  final profileName = cloudProfileName(instance);
  final linkedProfile = profileProvider.getProfileByName(profileName);
  final shouldDisconnect = linkedProfile != null &&
      profileProvider.activeProfile?.id == linkedProfile.id &&
      vpnProvider.status != VpnStatus.disconnected;

  // A node the provider already confirmed is gone can't be deleted via the
  // API (it no longer exists) — just drop the local record/profile.
  final success = instance.missing
      ? await cloudProvider.purgeMissingInstance(instance.id)
      : await cloudProvider.deleteInstance(instance.id);
  var disconnectSuccess = true;
  var profileCleanupSuccess = true;

  if (success && shouldDisconnect) {
    disconnectSuccess = await vpnProvider.disconnect();
  }

  if (success) {
    profileCleanupSuccess = await profileProvider.deleteProfileByName(
      profileName,
    );
    // Tear down the node's CDN Worker too — otherwise it's orphaned on
    // Cloudflare with its relay backend destroyed (every request 502s).
    // Best-effort: a failure here must not block the node deletion result.
    if (cdnProvider.deploymentFor(instance.id) != null) {
      try {
        await cdnProvider.deleteWorkerForNode(instance.id);
      } catch (_) {}
    }
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

Future<void> confirmRepairCloudNode({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  required CloudInstance instance,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showNodesConfirmationDialog(
    context: context,
    title: l10n.repairNodeTitle,
    message: l10n.repairNodeConfirm(instance.label),
    confirmLabel: l10n.repairNode,
    confirmColor: Colors.orange,
  );
  if (!confirmed) {
    return;
  }

  final owner = CloudProviderId.tryParse(instance.provider);
  final profileName = cloudProfileName(instance);
  final linkedProfile = profileProvider.getProfileByName(profileName);
  final shouldDisconnect = owner == CloudProviderId.ssh &&
      linkedProfile != null &&
      profileProvider.activeProfile?.id == linkedProfile.id &&
      vpnProvider.status != VpnStatus.disconnected;

  // Same "working…" feedback as the create flow — a redeploy re-runs the
  // full VPS provision + install and was equally silent before.
  _showDeployProgressDialog(
      context, AppLocalizations.of(context)!.nodeDeploying);

  var disconnectSuccess = true;
  if (shouldDisconnect) {
    disconnectSuccess = await vpnProvider.disconnect();
  }

  final success = await cloudProvider.repairInstance(instance.id);
  final replacementId = cloudProvider.lastCreatedInstanceId;
  final createdReplacement =
      success && replacementId != null && replacementId != instance.id;
  var profileUpdateSuccess = true;

  if (success && !createdReplacement && linkedProfile != null) {
    final refreshed = cloudProvider.allInstances
        .where((candidate) => candidate.id == instance.id)
        .firstOrNull;
    final config = cloudProvider.generateNodeConfig(refreshed ?? instance);
    if (config != null) {
      profileUpdateSuccess = await profileProvider.saveProfileContent(
        linkedProfile.id,
        config,
      );
    }
  }

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
  if (!context.mounted) {
    return;
  }

  final l10nFeedback = AppLocalizations.of(context)!;
  final operationSucceeded =
      success && disconnectSuccess && profileUpdateSuccess;
  final message = success
      ? createdReplacement
          ? l10nFeedback.nodeRedeployStarted
          : operationSucceeded
              ? l10nFeedback.nodeRepairCompleted
              : l10nFeedback.nodeRepairCleanupNeeded
      : cloudProvider.error ?? l10nFeedback.failedToRepair;
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
  final saved = await showSettingsApiKeyDialog(
    context: context,
    cloud: cloudProvider,
  );
  if (!saved || !context.mounted) {
    return;
  }
  await onSaved();
}

/// Non-dismissible modal progress dialog shown while a long cloud action
/// (node create / redeploy) is in flight, so the user gets explicit
/// "working…" feedback instead of a screen that looks frozen after the
/// form dialog closes. Dismiss by popping the root navigator once the
/// action completes.
void _showDeployProgressDialog(BuildContext context, String message) {
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 18),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  ));
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

  // Block with a visible progress dialog while the VPS is created and its
  // install script is kicked off. Without this the create flow looked
  // frozen: the form dialog closed and nothing happened on screen for the
  // multi-second (sometimes minute-plus) createInstance round-trip, so
  // users couldn't tell whether their tap registered or what was going on.
  _showDeployProgressDialog(
      context, AppLocalizations.of(context)!.nodeDeploying);

  final success = await cloudProvider.createInstance(
    region: request.region,
    plan: request.plan,
    label: request.label,
  );

  // Dismiss the progress dialog before any snackbar / follow-up CDN deploy.
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
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

  // Chain a CDN Worker deploy onto the new node if the user kept the
  // checkbox in the create dialog. We deliberately do this AFTER the
  // create-success snackbar so a CDN failure can show its own follow-up
  // toast instead of replacing the primary "creating…" message. Errors
  // are non-fatal: if the Worker deploy fails, the node still exists and
  // the user can retry from Settings → CDN.
  if (success &&
      request.autoDeployCdnWorker &&
      cloudProvider.lastCreatedInstanceId != null) {
    await _autoDeployCdnWorkerAfterCreate(
      context: context,
      cloudProvider: cloudProvider,
      instanceId: cloudProvider.lastCreatedInstanceId!,
    );
  }
}

/// Polls CloudProvider until the newly-created instance shows a valid
/// `vlessRelayPort` (the M1 install script needs to finish before the
/// CDN Worker can target it), then calls cdnProvider.deployWorkerForNode.
/// Bounded — gives up after a reasonable window so the user isn't left
/// waiting indefinitely if the VPS install hangs.
Future<void> _autoDeployCdnWorkerAfterCreate({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required String instanceId,
}) async {
  final cdnProvider = context.read<CdnProvider>();
  if (cdnProvider.status != CdnStatus.verified) {
    return;
  }
  final l10n = AppLocalizations.of(context)!;

  // Wait for relay port to materialise. The M1 install script (~3–5 min
  // on first boot) writes nodeInfo.vlessRelayPort once it finishes. Poll
  // every 10 s for up to 10 minutes — the createInstance flow already
  // waited for service-ready before returning, so this is mostly a
  // safety net for edge cases where the record lookup is racy.
  CloudInstance? readyInstance;
  for (var i = 0; i < 60 && context.mounted; i++) {
    final inst =
        cloudProvider.allInstances.where((c) => c.id == instanceId).firstOrNull;
    // BOTH must be present before we deploy: the relay port (written into the
    // local record at create time, so it appears almost immediately) AND a
    // populated IPv4 (only filled once a Vultr list refresh returns the
    // assigned address). Gating on the port alone exits on the first poll
    // with ipv4 still null, which made deployWorkerForNode render
    // BACKEND=":<port>" — a Worker that 502s on every relay forever.
    if (inst != null &&
        (inst.nodeInfo?.vlessRelayPort ?? 0) > 0 &&
        (inst.ipv4 ?? '').isNotEmpty) {
      readyInstance = inst;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 10));
    // Refresh so newly-discovered relay ports become visible.
    if (i % 3 == 0) {
      await cloudProvider.loadInstances(notify: false);
    }
  }
  if (!context.mounted) {
    return;
  }
  if (readyInstance == null) {
    showNodesActionSnackBar(
      context,
      message: l10n.cdnAutoDeployTimedOut,
      backgroundColor: Colors.orange,
    );
    return;
  }

  final ok = await cdnProvider.deployWorkerForNode(
    nodeId: readyInstance.id,
    nodeLabel: readyInstance.label,
    backendHost: readyInstance.ipv4 ?? '',
    backendPort: readyInstance.nodeInfo!.vlessRelayPort,
    // User opted into "deploy CDN after create" via the cloud-node
    // creation dialog checkbox — it's a direct decision, not a
    // background recovery, so track it as manual.
    deployedBy: 'manual',
  );
  if (!context.mounted) {
    return;
  }
  showNodesActionSnackBar(
    context,
    message: ok
        ? l10n.cdnAutoDeployDone(readyInstance.label)
        : (cdnProvider.lastError ?? l10n.cdnAutoDeployFailed),
    backgroundColor: ok ? Colors.green : Colors.orange,
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
      error: latencyResult.error ??
          AppLocalizations.of(context)!.nodeNotReadyForSpeedTest,
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

  final previousSession = capturePreviousVpnSession(
    vpnProvider: vpnProvider,
  );

  var benchmarkResult = latencyResult;
  try {
    if (previousSession.connected) {
      await vpnProvider.disconnect();
    }

    final benchmarkConfig = normalizeProfileConfigForCurrentPlatform(config);
    final connected = await vpnProvider.connect(
      configJson: benchmarkConfig,
      profileName: cloudProfileName(instance),
      stabilityCheckDuration: const Duration(seconds: 3),
      statusPollInterval: const Duration(milliseconds: 500),
    );

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
      final l10nFailure = AppLocalizations.of(context)!;
      benchmarkResult = benchmarkResult.copyWith(
        error: vpnProvider.error == null
            ? l10nFailure.failedToConnectSpeedTestTunnel
            : localizeVpnStatusMessage(vpnProvider.error, l10nFailure),
      );
    }

    cloudProvider.saveLatencyCheck(instance.id, benchmarkResult);
  } finally {
    if (previousSession.canRestore) {
      if (vpnProvider.status == VpnStatus.connected) {
        await vpnProvider.disconnect();
      }
      await restorePreviousVpnSession(
        session: previousSession,
        vpnProvider: vpnProvider,
      );
    } else if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }
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

  final previousSession = capturePreviousVpnSession(
    vpnProvider: vpnProvider,
  );
  final runThroughputProbe = throughputProbe ?? runCloudThroughputProbe;
  var restoreFailed = false;

  showNodesActionSnackBar(
    context,
    message: l10nBench.benchmarkingNodes,
    backgroundColor: Colors.blue,
    replaceCurrent: true,
  );

  cloudProvider.markBenchmarkAllStart();
  var selection = CloudFastestNodeSelection(
    error: l10nBench.noReadyNodeForTesting,
  );
  try {
    if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }

    for (var index = 0; index < readyNodes.length; index += 1) {
      if (cloudProvider.benchmarkAbortRequested) {
        break;
      }
      final instance = readyNodes[index];
      if (context.mounted) {
        final l10nProgress = AppLocalizations.of(context)!;
        showNodesActionSnackBar(
          context,
          message: l10nProgress.benchmarkingNode(
              instance.label, index + 1, readyNodes.length),
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
          error: vpnProvider.error == null
              ? l10nBench.failedToConnectBenchmarkTunnel
              : localizeVpnStatusMessage(vpnProvider.error, l10nBench),
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
    final aborted = cloudProvider.benchmarkAbortRequested;
    cloudProvider.markBenchmarkAllEnd();
    // When the user aborted to start their own connection, don't restore the
    // previous tunnel — the new connect flow will handle it.
    if (!aborted && previousSession.canRestore) {
      final restored = await restorePreviousVpnSession(
        session: previousSession,
        vpnProvider: vpnProvider,
      );
      restoreFailed = !restored;
    } else if (!aborted && vpnProvider.status == VpnStatus.connected) {
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
      message: selection.error ?? l10nResult.noReadyNodeForTesting,
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
  final latencySuffix =
      latencyMs != null ? ' \u2022 ${l10nResult.msLatency(latencyMs)}' : '';
  final endpointSuffix =
      endpoint != null && endpoint.isNotEmpty ? ' via $endpoint' : '';
  final restoreSuffix =
      restoreFailed ? ' \u2022 ${l10nResult.restoreConnectionFailed}' : '';
  showNodesActionSnackBar(
    context,
    message: l10nResult.bestBenchmark(selection.instance!.label,
        throughputSuffix, '$endpointSuffix$latencySuffix$restoreSuffix'),
    backgroundColor: restoreFailed ? Colors.orange : Colors.green,
    replaceCurrent: true,
  );
}
