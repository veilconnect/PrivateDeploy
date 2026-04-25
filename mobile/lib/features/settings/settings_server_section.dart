import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../cloud/ssh_deployer.dart';
import 'settings_cloud_dialogs.dart';

class SettingsServerSection extends StatelessWidget {
  const SettingsServerSection({
    Key? key,
    required this.onEditApiKey,
    required this.onExportBackup,
    required this.onImportBackup,
    required this.onClearLocalCloudData,
  }) : super(key: key);

  final Future<void> Function(CloudProvider cloud) onEditApiKey;
  final Future<void> Function(CloudProvider cloud) onExportBackup;
  final Future<void> Function(CloudProvider cloud) onImportBackup;
  final Future<void> Function() onClearLocalCloudData;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child:
                Text(l10n.server, style: Theme.of(context).textTheme.titleMedium),
          ),
          Consumer<CloudProvider>(
            builder: (context, cloud, _) {
              final isSsh = cloud.providerId == CloudProviderId.ssh;
              return Column(
                children: [
                  ListTile(
                    leading: Icon(
                      isSsh ? Icons.terminal_outlined : Icons.vpn_key,
                    ),
                    title: Text(isSsh ? l10n.sshAccess : l10n.apiKey),
                    subtitle: Text(
                      isSsh
                          ? (cloud.providerExtra.isEmpty
                              ? l10n.notSet
                              : sshAccessSummary(cloud.providerExtra))
                          : maskedSettingsApiKey(
                              cloud.apiKey,
                              notSetLabel: l10n.notSet,
                            ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onEditApiKey(cloud),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.copy_all_outlined),
                    title: Text(l10n.copyCloudBackup),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onExportBackup(cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.restore_outlined),
                    title: Text(l10n.restoreCloudBackup),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onImportBackup(cloud),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(l10n.clearLocalCloudData),
                    subtitle: Text(l10n.clearLocalCloudDataDesc),
                    onTap: onClearLocalCloudData,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
