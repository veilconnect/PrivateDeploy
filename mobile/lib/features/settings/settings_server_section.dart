import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

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
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child:
                Text('Server', style: Theme.of(context).textTheme.titleMedium),
          ),
          Consumer<CloudProvider>(
            builder: (context, cloud, _) {
              return Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.link),
                    title: Text('Standalone Cloud Access'),
                    subtitle: Text('This device directly calls the Vultr API'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key),
                    title: const Text('API Key'),
                    subtitle: Text(maskedSettingsApiKey(cloud.apiKey)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onEditApiKey(cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('Cloud Provider'),
                    subtitle: Text('${cloud.providerName} (direct)'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.copy_all_outlined),
                    title: const Text('Copy Cloud Backup'),
                    subtitle: const Text(
                      'Copy API key and local node records as JSON',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onExportBackup(cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.restore_outlined),
                    title: const Text('Restore Cloud Backup'),
                    subtitle: const Text(
                      'Paste a backup JSON to restore API key and nodes',
                    ),
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
