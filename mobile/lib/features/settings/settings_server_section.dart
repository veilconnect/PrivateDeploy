import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';
import 'settings_cloud_dialogs.dart';

class SettingsServerSection extends StatelessWidget {
  const SettingsServerSection({
    Key? key,
    required this.onEditApiKey,
    required this.onExportBackup,
    required this.onImportBackup,
  }) : super(key: key);

  final Future<void> Function(CloudProvider cloud) onEditApiKey;
  final Future<void> Function(CloudProvider cloud) onExportBackup;
  final Future<void> Function(CloudProvider cloud) onImportBackup;

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
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: Text(l10n.standaloneCloudAccess),
                    subtitle: Text(l10n.standaloneCloudAccessDesc),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key),
                    title: Text(l10n.apiKey),
                    subtitle: Text(maskedSettingsApiKey(cloud.apiKey, notSetLabel: l10n.notSet)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onEditApiKey(cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: Text(l10n.cloudProvider),
                    subtitle: Text(l10n.cloudProviderDirect(cloud.providerName)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(l10n.sensitiveData),
                    subtitle: Text(l10n.sensitiveDataDesc),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.copy_all_outlined),
                    title: Text(l10n.copyCloudBackup),
                    subtitle: Text(l10n.copyCloudBackupDesc),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onExportBackup(cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.restore_outlined),
                    title: Text(l10n.restoreCloudBackup),
                    subtitle: Text(l10n.restoreCloudBackupDesc),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onImportBackup(cloud),
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
