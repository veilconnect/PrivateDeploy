import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/subscription/parser.dart';
import '../../core/subscription/subscription_fetcher.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/utils/logger.dart';
import '../cloud/cloud_throughput_probe.dart';
import '../profiles/profile_config_normalizer.dart';
import '../profiles/profile_provider.dart';
import '../settings/app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_action_feedback.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialogs.dart';
import 'nodes_profile_widgets.dart';

String _subscriptionSourceLabel(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri?.host.isNotEmpty == true ? uri!.host : 'unknown source';
}

Future<void> confirmDeleteProfile({
  required BuildContext context,
  required ProfileProvider profileProvider,
  required Profile profile,
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

  final success = await profileProvider.deleteProfile(profile.id);
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
  Future<Object?> Function(String url)? fetchSubscriptionData,
  String? Function(Object? responseData)? parseSubscriptionData,
}) async {
  final request = await showNodesImportProfileDialog(
    context,
    validateName: profileProvider.validateProfileName,
  );
  if (request == null || !context.mounted) {
    return;
  }

  final input = request.url.trim();

  // Check if input is proxy URIs (not an HTTP URL)
  final uri = Uri.tryParse(input);
  final isHttpUrl = uri != null &&
      uri.hasAuthority &&
      (uri.scheme == 'http' || uri.scheme == 'https');

  if (!isHttpUrl) {
    // Parse proxy URIs directly
    final config = normalizeToSingboxConfig(input);
    if (config == null || config == '{}') {
      if (context.mounted) {
        showNodesActionSnackBar(
          context,
          message: AppLocalizations.of(context)!.failedToParseProxyLinks,
          backgroundColor: Colors.red,
        );
      }
      return;
    }

    final profileName = request.name.isNotEmpty
        ? request.name
        : 'Import ${DateTime.now().toString().substring(0, 16)}';
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
          '[Nodes] Imported proxy profile "$profileName" but could not resolve it for activation',
        );
      }
    }

    if (!context.mounted) return;
    final l10nImport = AppLocalizations.of(context)!;
    showNodesActionSnackBar(
      context,
      message: success
          ? l10nImport.importedSuccess
          : profileProvider.error ?? l10nImport.failedToImport,
      backgroundColor: success ? Colors.green : Colors.red,
    );
    return;
  }

  showNodesActionSnackBar(
    context,
    message: AppLocalizations.of(context)!.fetchingSubscription,
    backgroundColor: Colors.grey.shade800,
  );

  try {
    final sourceLabel = _subscriptionSourceLabel(request.url);
    final responseData =
        await (fetchSubscriptionData ?? fetchSubscriptionResponseData)(
      request.url,
    );
    final config = (parseSubscriptionData ??
        SubscriptionParser.parseResponseDataToSingboxConfig)(responseData);
    if (config == null) {
      AppLogger.warning(
        '[Nodes] Failed to parse subscription response from $sourceLabel',
      );
      if (context.mounted) {
        showNodesActionSnackBar(
          context,
          message: AppLocalizations.of(context)!.failedToParseSubscription,
          backgroundColor: Colors.red,
          replaceCurrent: true,
        );
      }
      return;
    }

    final profileName = request.name.isNotEmpty
        ? request.name
        : 'Sub ${DateTime.now().toString().substring(0, 16)}';
    final success = await profileProvider.createProfile(
      name: profileName,
      subscriptionUrl: request.url,
      content: config,
    );
    if (success) {
      final created = profileProvider.getProfileByName(profileName);
      if (created != null) {
        await profileProvider.activateProfile(created.id);
      } else {
        AppLogger.warning(
          '[Nodes] Imported subscription profile "$profileName" but could not resolve it for activation',
        );
      }
    }

    if (success) {
      AppLogger.info(
        '[Nodes] Imported subscription profile "$profileName" from $sourceLabel',
      );
    } else {
      AppLogger.warning(
        '[Nodes] Failed to create imported profile "$profileName" from $sourceLabel: '
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
      replaceCurrent: true,
    );
  } catch (e, stackTrace) {
    AppLogger.error('[Nodes] Subscription import failed', e, stackTrace);
    if (!context.mounted) {
      return;
    }

    showNodesActionSnackBar(
      context,
      message: AppLocalizations.of(context)!.networkError('$e'),
      backgroundColor: Colors.red,
      replaceCurrent: true,
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
  final config = normalizeToSingboxConfig(rawConfig);
  if (config == null || config == '{}') {
    showNodesActionSnackBar(
      context,
      message: AppLocalizations.of(context)!.unrecognizedConfigFormat,
      backgroundColor: Colors.red,
    );
    return;
  }

  final configError = validateSingboxConfig(config);
  if (configError != null) {
    showNodesActionSnackBar(
      context,
      message: configError,
      backgroundColor: Colors.red,
    );
    return;
  }

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
  final configJson = await profileProvider.getProfileContent(profile.id);
  if (configJson == null || configJson.isEmpty) {
    return const ProfileSpeedResult(error: 'No config available');
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
      error: vpnProvider.error ?? l10n.failedToConnectSpeedTestTunnel,
    );
  }

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
