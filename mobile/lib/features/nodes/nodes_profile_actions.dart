import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/security/encrypted_share.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/utils/logger.dart';
import '../cloud/cloud_throughput_probe.dart';
import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import '../vpn/vpn_status_messages.dart';
import 'nodes_action_feedback.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialogs.dart';
import 'nodes_profile_widgets.dart';

Future<void> confirmDeleteProfile({
  required BuildContext context,
  required ProfileProvider profileProvider,
  required Profile profile,
  VpnProvider? vpnProvider,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showNodesDeleteConfirmationDialog(
    context: context,
    title: l10n.deleteProfile,
    message: l10n.deleteProfileConfirm(profile.name),
  );
  if (!confirmed) {
    return;
  }

  // If the VPN is connected to this exact profile, tear the tunnel down first
  // so the connection card doesn't keep showing a stale "已连接 / 4m 38s" badge
  // after the underlying profile is gone (verified on Pixel 7 v2.0.0+15).
  if (vpnProvider != null &&
      vpnProvider.isConnected &&
      vpnProvider.activeProfile == profile.name) {
    await vpnProvider.disconnect();
  }

  final success = await profileProvider.deleteProfile(profile.id);
  if (success) {
    // The error banner usually points at a failed connection / probe for the
    // profile we just deleted. Clearing it avoids a stale notice (with a
    // dangling "Retry" action) lingering after the underlying source is gone.
    vpnProvider?.clearError();
  }
  if (!context.mounted) {
    return;
  }

  final l10nFeedback = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nFeedback.profileDeleted
        : profileProvider.error ?? l10nFeedback.failedToDeleteProfile,
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

Future<void> showRenameProfileFlow({
  required BuildContext context,
  required Profile profile,
  required ProfileProvider profileProvider,
}) async {
  final name = await showNodesRenameProfileDialog(
    context: context,
    initialName: profile.name,
    validateName: (value) => profileProvider.validateProfileName(
      value,
      excludeId: profile.id,
    ),
  );
  if (name == null || !context.mounted) {
    return;
  }

  final success = await profileProvider.updateProfile(
    id: profile.id,
    name: name,
  );
  if (!context.mounted) {
    return;
  }

  final l10nRename = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nRename.profileRenamed
        : profileProvider.error ?? l10nRename.failedToRename,
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

Future<void> showImportProfileFlow({
  required BuildContext context,
  required ProfileProvider profileProvider,
}) async {
  final request = await showNodesImportProfileDialog(
    context,
    validateName: profileProvider.validateProfileName,
  );
  if (request == null || !context.mounted) {
    return;
  }

  try {
    final payload = await EncryptedShareCodec.decrypt(
      armored: request.payload,
      passphrase: request.passphrase,
    );

    String? config;
    switch (payload.kind) {
      case EncryptedShareKind.proxyLinks:
        config = normalizeToSingboxConfig(payload.content);
        if (config == null || config == '{}') {
          throw const FormatException('Encrypted config could not be parsed');
        }
        break;
      case EncryptedShareKind.profileConfig:
        final configError = validateSingboxConfig(
          payload.content,
          AppLocalizations.of(context)!,
        );
        if (configError != null) {
          throw FormatException(configError);
        }
        config = const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(payload.content) as Map<String, dynamic>);
        break;
      default:
        throw const FormatException(
          'This encrypted content is not a shareable route config',
        );
    }

    final profileName = request.name.isNotEmpty
        ? request.name
        : ((payload.label ?? '').trim().isNotEmpty
            ? payload.label!.trim()
            : 'Import ${DateTime.now().toString().substring(0, 16)}');
    final success = await profileProvider.createProfile(
      name: profileName,
      content: config,
    );
    if (success) {
      final created = profileProvider.getProfileByName(profileName);
      if (created != null) {
        await profileProvider.activateProfile(created.id);
      } else {
        AppLogger.warning(
          '[Nodes] Imported encrypted profile "$profileName" but could not resolve it for activation',
        );
      }
    }

    if (success) {
      AppLogger.info(
        '[Nodes] Imported encrypted profile "$profileName"',
      );
    } else {
      AppLogger.warning(
        '[Nodes] Failed to create imported encrypted profile "$profileName": '
        '${profileProvider.error ?? 'unknown error'}',
      );
    }

    if (!context.mounted) {
      return;
    }

    final l10nSubImport = AppLocalizations.of(context)!;
    showNodesActionSnackBar(
      context,
      message: success
          ? l10nSubImport.importedSuccess
          : profileProvider.error ?? l10nSubImport.failedToImport,
      backgroundColor: success ? Colors.green : Colors.red,
    );
  } catch (e, stackTrace) {
    AppLogger.error('[Nodes] Encrypted import failed', e, stackTrace);
    if (!context.mounted) {
      return;
    }

    showNodesActionSnackBar(
      context,
      message: AppLocalizations.of(context)!.encryptedImportFailed('$e'),
      backgroundColor: Colors.red,
    );
  }
}

Future<void> showCreateProfileFlow({
  required BuildContext context,
  required ProfileProvider profileProvider,
}) async {
  final request = await showNodesCreateProfileDialog(
    context,
    validateName: profileProvider.validateProfileName,
  );
  if (request == null || !context.mounted) {
    return;
  }

  final profileName = request.name.trim();
  final rawConfig = request.config.trim();
  final configError = validateSingboxConfig(
    rawConfig,
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

  final config = const JsonEncoder.withIndent('  ')
      .convert(jsonDecode(rawConfig) as Map<String, dynamic>);

  final success = await profileProvider.createProfile(
    name: profileName,
    content: config,
  );
  if (!context.mounted) {
    return;
  }

  final l10nCreate = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nCreate.profileCreatedSuccess
        : profileProvider.error ?? l10nCreate.failedToCreateProfile,
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

/// Collects WireGuard connection fields via a form and creates a connectable
/// full-tunnel profile from them — the "configure WireGuard like a VPN" flow.
/// Mirrors [showCreateProfileFlow] but generates the sing-box config from the
/// form instead of asking the user to paste raw JSON.
Future<void> showCreateWireguardFlow({
  required BuildContext context,
  required ProfileProvider profileProvider,
}) async {
  final request = await showNodesWireguardProfileDialog(
    context,
    validateName: profileProvider.validateProfileName,
  );
  if (request == null || !context.mounted) {
    return;
  }

  final profileName = request.name.trim();
  final rawConfig = request.config.trim();
  final configError = validateSingboxConfig(
    rawConfig,
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

  final config = const JsonEncoder.withIndent('  ')
      .convert(jsonDecode(rawConfig) as Map<String, dynamic>);

  final success = await profileProvider.createProfile(
    name: profileName,
    content: config,
  );
  if (!context.mounted) {
    return;
  }

  final l10nCreate = AppLocalizations.of(context)!;
  showNodesActionSnackBar(
    context,
    message: success
        ? l10nCreate.profileCreatedSuccess
        : profileProvider.error ?? l10nCreate.failedToCreateProfile,
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

/// Run a throughput speed test for a manual profile.
///
/// Temporarily connects VPN with the profile's config, measures download
/// throughput, then restores the previous connection.
Future<ProfileSpeedResult> testProfileSpeed({
  required BuildContext context,
  required Profile profile,
  required ProfileProvider profileProvider,
  required VpnProvider vpnProvider,
  Future<CloudThroughputSample> Function()? throughputProbe,
}) async {
  final l10nEarly = AppLocalizations.of(context)!;
  final configJson = await profileProvider.getProfileContent(profile.id);
  if (configJson == null || configJson.isEmpty) {
    return ProfileSpeedResult(
      error: l10nEarly.failedToConnectSpeedTestTunnel,
    );
  }

  // Pre-validate so a corrupted profile fails fast with a friendly message
  // rather than triggering a real connection attempt that bubbles a raw
  // sing-box parser error (and the entire config body) into the UI banner.
  final preflightError = validateNodeConfig(configJson, l10nEarly);
  if (preflightError != null) {
    return ProfileSpeedResult(error: preflightError);
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

  final benchmarkConfig = normalizeProfileConfigForCurrentPlatform(configJson);
  final connected = await vpnProvider.connect(
    configJson: benchmarkConfig,
    profileName: profile.name,
    stabilityCheckDuration: const Duration(seconds: 3),
    statusPollInterval: const Duration(milliseconds: 500),
  );

  ProfileSpeedResult result;
  if (connected) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final probe = throughputProbe ?? runCloudThroughputProbe;
    final sample = await probe();
    result = ProfileSpeedResult(
      throughputMbps: sample.speedMbps,
      error: sample.hasSample ? null : sample.error,
    );
    await vpnProvider.disconnect();
  } else {
    final l10n = AppLocalizations.of(context)!;
    result = ProfileSpeedResult(
      error: vpnProvider.error == null
          ? l10n.failedToConnectSpeedTestTunnel
          : localizeVpnStatusMessage(vpnProvider.error, l10n),
    );
  }

  // The speed-test result is shown inline on the profile card. Clearing the
  // sticky banner here avoids the failure lingering on the connection card
  // after the user has already seen the inline result.
  vpnProvider.clearError();

  // Restore previous VPN connection if one was active.
  if (previouslyConnected && previousConfigJson != null) {
    await vpnProvider.connect(
      configJson: previousConfigJson,
      profileName: previousProfileName,
      stabilityCheckDuration: const Duration(seconds: 1),
      statusPollInterval: const Duration(milliseconds: 250),
    );
  }

  return result;
}
