import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../profiles/bundled_rule_set_registry.dart';
import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import '../vpn/vpn_status_messages.dart';
import 'nodes_action_feedback.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialogs.dart';

/// Context-free auto-failover used by `VpnProvider`'s upstream-degraded
/// watchdog. Picks the next ready cloud node not in [triedProfileNames],
/// switches to it, and returns true if a switch was actually attempted.
///
/// Why this lives alongside the UI handlers: it shares profile-activation
/// and config-generation steps with `useCloudNodeAndConnect`, just without
/// the BuildContext-bound snackbars. Keeping them together makes the
/// invariants (skip already-tried, generate fresh config, swap profile,
/// trigger connect) reviewable in one place.
Future<bool> autoFailoverToNextCloudNode({
  required CloudProvider cloudProvider,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  required Set<String> triedProfileNames,
  VpnRoutingSettings routingSettings = VpnRoutingSettings.defaults,
}) async {
  final candidates = connectableCloudInstances(cloudProvider)
      .where((inst) => !triedProfileNames.contains(cloudProfileName(inst)))
      .toList();

  for (final instance in candidates) {
    final profileName = cloudProfileName(instance);
    final config = cloudProvider.generateNodeConfig(instance);
    if (config == null) {
      continue;
    }

    final existing = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;

    var ok = true;
    if (existing == null) {
      ok = await profileProvider.createProfile(
        name: profileName,
        content: config,
        allowReservedPrefix: true,
      );
      if (ok) {
        final created = profileProvider.profiles
            .where((profile) => profile.name == profileName)
            .firstOrNull;
        if (created != null) {
          ok = await profileProvider.activateProfile(created.id);
        } else {
          ok = false;
        }
      }
    } else {
      ok = await profileProvider.saveProfileContent(existing.id, config);
      if (ok) {
        ok = await profileProvider.activateProfile(existing.id);
      }
    }
    if (!ok) {
      continue;
    }

    // Disconnect the current degraded tunnel before bringing the new node
    // up. VpnProvider.connect() doesn't auto-stop the existing session and
    // the native side rejects startVpn() while isRunning=true.
    if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }
    final connected = await vpnProvider.connect(
      // Normalize with the user's routing settings so the failover node keeps
      // the custom rules (connecting the raw node config
      // would silently drop them). Bundled rule-set paths must come along
      // too — without them the normalizer cannot emit the pd-geosite-cn /
      // pd-geoip-cn direct rules and split-mode users lose CN routing after
      // a failover.
      configJson: normalizeProfileConfigForCurrentPlatform(
        config,
        routingSettings: routingSettings,
        bundledRuleSetPaths: BundledRuleSetRegistry.paths,
      ),
      profileName: profileName,
      stabilityCheckDuration: const Duration(seconds: 6),
      statusPollInterval: const Duration(milliseconds: 500),
    );
    if (connected && !vpnProvider.isDegraded) {
      // Healthy on the new node — failover succeeded.
      return true;
    }
    // Otherwise the new node is also degraded; loop will try the next.
    // Note: connect() resets _upstreamDegradedRestartAttempts to 0, so the
    // new node gets its own restart budget too.
  }

  // If cloud access is unavailable (for example Android secure storage was
  // reset and API keys cannot be decrypted), the app may still have usable
  // cached Cloud profiles in Hive. Try those before giving up so a saved
  // backup route can recover the user without needing provider metadata.
  final savedCandidates = profileProvider.profiles
      .where(isUsableSavedCloudProfile)
      .where((profile) => !triedProfileNames.contains(profile.name))
      .toList();
  for (final profile in savedCandidates) {
    final config = profile.content?.trim();
    if (config == null || config.isEmpty) {
      continue;
    }
    final activated = await profileProvider.activateProfile(profile.id);
    if (!activated) {
      continue;
    }
    if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }
    final connected = await vpnProvider.connect(
      configJson: normalizeProfileConfigForCurrentPlatform(
        config,
        routingSettings: routingSettings,
        bundledRuleSetPaths: BundledRuleSetRegistry.paths,
      ),
      profileName: profile.name,
      stabilityCheckDuration: const Duration(seconds: 6),
      statusPollInterval: const Duration(milliseconds: 500),
    );
    if (connected && !vpnProvider.isDegraded) {
      return true;
    }
  }
  return false;
}

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
      message: profileProvider.error ??
          AppLocalizations.of(context)!.failedToActivateNode,
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
      message: profileProvider.error ??
          AppLocalizations.of(context)!.failedToActivate,
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
  final successMessage = AppLocalizations.of(context)!.vpnConnectedSuccess;
  await connectSelectedProfile(
    context: context,
    vpnProvider: vpnProvider,
    profileProvider: profileProvider,
    cloudProvider: cloudProvider,
    onUseCloudNode: onUseCloudNode,
    autoSelectFastestCloudNode: true,
    successMessage: successMessage,
  );

  // Cold-start / first-node-unreachable fallback: if the primary attempt
  // left the VPN disconnected, or connected in the explicit upstream-blocked
  // state, cycle through the remaining ready cloud nodes. A startup probe
  // timeout is intentionally excluded: that signal can be transient during
  // Wi-Fi/cellular hand-offs and should not force a node switch.
  if (vpnProvider.status == VpnStatus.connected &&
      !_shouldTryBackupAfterConnect(vpnProvider)) {
    return;
  }

  final tried = <String>{};
  final activeName = profileProvider.activeProfile?.name;
  if (activeName != null) tried.add(activeName);

  var remaining = connectableCloudInstances(cloudProvider)
      .where((inst) => !tried.contains(cloudProfileName(inst)))
      .toList();
  // Prefer nodes with prior successful latency samples, then by creation
  // time. This biases toward nodes the app has seen working before.
  remaining.sort((a, b) {
    final la = cloudProvider.latencyCheckFor(a.id);
    final lb = cloudProvider.latencyCheckFor(b.id);
    final aHas = la?.latencyMs != null && la!.error == null;
    final bHas = lb?.latencyMs != null && lb!.error == null;
    if (aHas != bHas) return aHas ? -1 : 1;
    if (aHas && bHas) return la.latencyMs!.compareTo(lb.latencyMs!);
    return 0;
  });

  // Record that the first attempt failed so future fastest-node selection
  // scores past failures lower. latencyCheckFor is read-only; saveLatencyCheck
  // persists the failure into the same map the scorer reads from.
  final firstTried = connectableCloudInstances(cloudProvider)
      .where((inst) => cloudProfileName(inst) == activeName)
      .firstOrNull;
  if (firstTried != null) {
    cloudProvider.saveLatencyCheck(
      firstTried.id,
      CloudLatencyCheck.failure(
        error: AppLocalizations.of(context)!.restoreConnectionFailed,
        updatedAt: DateTime.now(),
        mode: CloudProbeMode.quick,
      ),
      notify: false,
    );
  }

  final total = remaining.length;
  for (var i = 0; i < remaining.length; i += 1) {
    final next = remaining[i];
    if (!context.mounted) return;
    if (vpnProvider.status == VpnStatus.connected &&
        !_shouldTryBackupAfterConnect(vpnProvider)) {
      return;
    }
    tried.add(cloudProfileName(next));
    if (context.mounted) {
      showNodesActionSnackBar(
        context,
        message: AppLocalizations.of(context)!.tryingBackupNode(
          i + 1,
          total,
          next.label,
        ),
        backgroundColor: Colors.blue,
        replaceCurrent: true,
      );
    }
    await useCloudNodeAndConnect(
      context: context,
      instance: next,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    );
    if (vpnProvider.status == VpnStatus.connected &&
        !_shouldTryBackupAfterConnect(vpnProvider)) {
      return;
    }
    // Record this failure too so the next cold-start auto-fastest can
    // deprioritise it.
    cloudProvider.saveLatencyCheck(
      next.id,
      CloudLatencyCheck.failure(
        error: AppLocalizations.of(context)!.restoreConnectionFailed,
        updatedAt: DateTime.now(),
        mode: CloudProbeMode.quick,
      ),
      notify: false,
    );
  }

  if (vpnProvider.status != VpnStatus.connected ||
      _shouldTryBackupAfterConnect(vpnProvider)) {
    final switched = await autoFailoverToNextCloudNode(
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
      triedProfileNames: tried,
      routingSettings: context.read<AppSettingsProvider>().vpnRoutingSettings,
    );
    if (switched ||
        (vpnProvider.status == VpnStatus.connected &&
            !_shouldTryBackupAfterConnect(vpnProvider))) {
      return;
    }
  }

  if (!context.mounted) return;
  if (vpnProvider.status != VpnStatus.connected ||
      _shouldTryBackupAfterConnect(vpnProvider)) {
    if (vpnProvider.status == VpnStatus.connected &&
        _shouldTryBackupAfterConnect(vpnProvider)) {
      await vpnProvider.stopDegradedSession(
        reason: vpnProvider.error ?? vpnProvider.diagnosticsError,
      );
      if (!context.mounted) return;
    }
    showNodesActionSnackBar(
      context,
      message: AppLocalizations.of(context)!.allNodesFailedCheckNetwork,
      backgroundColor: Colors.red,
      replaceCurrent: true,
    );
  }
}

bool _shouldTryBackupAfterConnect(VpnProvider vpnProvider) {
  if (vpnProvider.status != VpnStatus.connected || !vpnProvider.isDegraded) {
    return false;
  }
  final warning = vpnProvider.error ?? vpnProvider.diagnosticsError;
  return warning != VpnProvider.startupProbeInconclusiveMessage;
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
        : (vpnProvider.error == null
            ? l10nDisconnect.failedToDisconnectVpn
            : localizeVpnStatusMessage(vpnProvider.error, l10nDisconnect)),
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
  // If a benchmark-all pass is in progress, abort it so the user's explicit
  // connect request wins. Wait briefly for the benchmark loop to unwind its
  // current VPN transition before proceeding.
  if (cloudProvider.isBenchmarkingAll) {
    cloudProvider.requestBenchmarkAllAbort();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (
        cloudProvider.isBenchmarkingAll && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (vpnProvider.status == VpnStatus.connected) {
      await vpnProvider.disconnect();
    }
  }

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
  final activeCloudInstance =
      activeProfile != null && isCloudManagedProfile(activeProfile)
          ? readyCloudNodes
              .where((inst) => cloudProfileName(inst) == activeProfile.name)
              .firstOrNull
          : null;

  if (activeCloudInstance != null) {
    final refreshedConfig =
        cloudProvider.generateNodeConfig(activeCloudInstance);
    if (refreshedConfig != null) {
      final refreshed = await profileProvider.saveProfileContent(
        activeProfile!.id,
        refreshedConfig,
      );
      if (!refreshed) {
        if (!context.mounted) {
          return;
        }
        showNodesActionSnackBar(
          context,
          message: profileProvider.error ??
              AppLocalizations.of(context)!.failedToActivateNode,
          backgroundColor: Colors.red,
        );
        return;
      }
    }
  }

  if (autoSelectFastestCloudNode &&
      (activeProfile == null ||
          (isCloudManagedProfile(activeProfile) &&
              activeCloudInstance == null))) {
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
      message: cloudProvider.allInstances.isNotEmpty
          ? l10nHint.noCredentialsHint
          : l10nHint.noNodeSelectedHint,
      backgroundColor: Colors.orange,
    );
    return;
  }

  final configError = validateSingboxConfig(
    configJson,
    AppLocalizations.of(context)!,
  );
  if (configError != null) {
    showNodesActionSnackBar(
      context,
      message: configError,
      backgroundColor: Colors.red,
    );
    return;
  }

  final bool alreadyConnected = vpnProvider.status == VpnStatus.connected;

  if (alreadyConnected) {
    final disconnected = await vpnProvider.disconnect();
    if (!disconnected) {
      if (context.mounted) {
        final l10nSwitch = AppLocalizations.of(context)!;
        showNodesActionSnackBar(
          context,
          message: vpnProvider.error == null
              ? l10nSwitch.failedToSwitchActiveVpnNode
              : localizeVpnStatusMessage(vpnProvider.error, l10nSwitch),
          backgroundColor: Colors.red,
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
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

  final l10nResult = AppLocalizations.of(context)!;
  // connect() returns true even when native checkTunnelHealth came back
  // UpstreamDegraded/Unreachable (the tunnel is up but nothing routes). In
  // that case `vpnProvider.error` carries the warning text and `isDegraded`
  // is true. Show the warning in orange instead of a green success — a green
  // "VPN 连接成功" snackbar while the cellular session can't actually
  // browse is what triggered the 2026-05-12 bug report.
  final degraded = connected && vpnProvider.isDegraded;
  showNodesActionSnackBar(
    context,
    message: connected
        ? (degraded
            ? localizeVpnStatusMessage(
                vpnProvider.error ?? successMessage,
                l10nResult,
              )
            : successMessage)
        : (vpnProvider.error == null
            ? l10nResult.failedToConnectVpn
            : localizeVpnStatusMessage(vpnProvider.error, l10nResult)),
    backgroundColor:
        connected ? (degraded ? Colors.orange : Colors.green) : Colors.red,
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
      message:
          selection.error ?? AppLocalizations.of(context)!.noReadyCloudNode,
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
