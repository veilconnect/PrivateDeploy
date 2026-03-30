import 'package:flutter/material.dart';

import '../../core/subscription/parser.dart';
import '../../core/subscription/subscription_fetcher.dart';
import '../../shared/utils/logger.dart';
import '../profiles/profile_provider.dart';
import 'nodes_action_feedback.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialogs.dart';

String _subscriptionSourceLabel(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri?.host.isNotEmpty == true ? uri!.host : 'unknown source';
}

Future<void> confirmDeleteProfile({
  required BuildContext context,
  required ProfileProvider profileProvider,
  required Profile profile,
}) async {
  final confirmed = await showNodesDeleteConfirmationDialog(
    context: context,
    title: 'Delete Profile',
    message: 'Are you sure you want to delete "${profile.name}"?',
  );
  if (!confirmed) {
    return;
  }

  final success = await profileProvider.deleteProfile(profile.id);
  if (!context.mounted) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: success
        ? 'Profile deleted'
        : profileProvider.error ?? 'Failed to delete',
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

  showNodesActionSnackBar(
    context,
    message: success
        ? 'Profile renamed'
        : profileProvider.error ?? 'Failed to rename',
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

  showNodesActionSnackBar(
    context,
    message: 'Fetching subscription...',
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
          message: 'Failed to parse subscription',
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

    showNodesActionSnackBar(
      context,
      message: success
          ? 'Imported successfully'
          : profileProvider.error ?? 'Failed to import',
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
      message: 'Network error: $e',
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
  final config = request.config.trim();
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

  showNodesActionSnackBar(
    context,
    message: success
        ? 'Profile created successfully'
        : profileProvider.error ?? 'Failed to create profile',
    backgroundColor: success ? Colors.green : Colors.red,
  );
}
