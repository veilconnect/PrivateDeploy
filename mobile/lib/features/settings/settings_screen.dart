import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_provider.dart';
import 'settings_about_section.dart';
import 'settings_app_section.dart';
import 'settings_cloud_dialogs.dart';
import 'settings_help_section.dart';
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
    final l10n = AppLocalizations.of(context)!;
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
            tooltip: l10n.back,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _popRootRoute(context),
          ),
          title: Text(l10n.settings),
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
                onClearLocalCloudData: () async {
                  final cloud = context.read<CloudProvider>();
                  final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) {
                          final dl10n = AppLocalizations.of(dialogContext)!;
                          return AlertDialog(
                            title: Text(dl10n.clearLocalCloudDataTitle),
                            content: Text(
                              dl10n.clearLocalCloudDataConfirm(
                                cloud.providerId.displayName,
                              ),
                            ),
                            actions: [
                              OutlinedButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: Text(dl10n.cancel),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: Text(dl10n.clear),
                              ),
                            ],
                          );
                        },
                      ) ??
                      false;
                  if (!confirmed || !context.mounted) {
                    return;
                  }
                  await cloud.clearLocalCloudData();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(AppLocalizations.of(context)!
                              .localCloudDataCleared)),
                    );
                  }
                }),
            SizedBox(height: 16.h),
            const SettingsAppSection(),
            SizedBox(height: 16.h),
            const SettingsHelpSection(),
            SizedBox(height: 16.h),
            const SettingsAboutSection(),
          ],
        ),
      ),
    );
  }
}
