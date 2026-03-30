import 'dart:async';

import 'package:flutter/material.dart';

import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../profiles/profile_provider.dart';
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
  final confirmed = await showNodesDeleteConfirmationDialog(
    context: context,
    title: 'Delete Node',
    message:
        'Delete "${instance.label}"?\n\nThis will destroy the server permanently.',
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

  final operationSucceeded =
      success && disconnectSuccess && profileCleanupSuccess;
  final message = success
      ? operationSucceeded
          ? 'Node deleted'
          : 'Node deleted, but local cleanup needs attention'
      : cloudProvider.error ?? 'Failed to delete';
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
      return saved ? null : cloudProvider.error ?? 'Failed to save API key';
    },
  );
  if (!success || !context.mounted) {
    return;
  }

  await onSaved();
  if (!context.mounted) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: 'API key saved and verified',
    backgroundColor: Colors.green,
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

  showNodesActionSnackBar(
    context,
    message: success
        ? 'Node deploying... It takes 3-5 minutes.'
        : cloudProvider.error ?? 'Failed to create',
    backgroundColor: success ? Colors.green : Colors.red,
  );
}

Future<void> testCloudNodeLatency({
  required BuildContext context,
  required CloudProvider cloudProvider,
  required CloudInstance instance,
}) async {
  final result = await cloudProvider.testInstanceLatency(instance);
  if (!context.mounted || result.error == null) {
    return;
  }

  showNodesActionSnackBar(
    context,
    message: result.error!,
    backgroundColor: Colors.orange,
  );
}
