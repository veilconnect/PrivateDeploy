import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../cloud/cloud_provider.dart';
import 'settings_about_section.dart';
import 'settings_app_section.dart';
import 'settings_cloud_dialogs.dart';
import 'settings_server_section.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  Future<void> _popRootRoute(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        _popRootRoute(context);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _popRootRoute(context),
          ),
          title: const Text('Settings'),
        ),
        body: ListView(
          padding: EdgeInsets.all(16.w),
          children: [
            SettingsServerSection(
              onEditApiKey: (cloud) =>
                  showSettingsApiKeyDialog(context: context, cloud: cloud),
              onExportBackup: (cloud) => showSettingsBackupExportDialog(
                context: context,
                cloud: cloud,
              ),
              onImportBackup: (cloud) => showSettingsBackupImportDialog(
                context: context,
                cloud: cloud,
              ),
            ),
            SizedBox(height: 16.h),
            SettingsAppSection(onClearLocalCloudData: () async {
              final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Clear Local Cloud Data?'),
                      content: const Text(
                        'This removes the saved Vultr API key and cached cloud node records from this device only. It does not delete any cloud instances.',
                      ),
                      actions: [
                        OutlinedButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed || !context.mounted) {
                return;
              }
              final cloud = context.read<CloudProvider>();
              await cloud.clearLocalCloudData();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Local cloud data cleared')),
                );
              }
            }),
            SizedBox(height: 16.h),
            const SettingsAboutSection(),
          ],
        ),
      ),
    );
  }
}
