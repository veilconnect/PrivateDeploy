import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import 'nodes_test_keys.dart';

class NodesScreenFab extends StatelessWidget {
  final String? cloudAccessActionLabel;
  final VoidCallback? onConfigureCloudAccess;
  final VoidCallback? onCreateCloudNode;
  final VoidCallback onImportProfile;
  final VoidCallback onCreateProfile;
  final VoidCallback onAddWireguard;

  const NodesScreenFab({
    Key? key,
    this.cloudAccessActionLabel,
    this.onConfigureCloudAccess,
    this.onCreateCloudNode,
    required this.onImportProfile,
    required this.onCreateProfile,
    required this.onAddWireguard,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FloatingActionButton(
      key: NodesTestKeys.workspaceFab,
      tooltip: l10n.create,
      onPressed: () => _showActionSheet(context, l10n),
      child: const Icon(Icons.add),
    );
  }

  Future<void> _showActionSheet(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(8.w, 0, 8.w, 12.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (cloudAccessActionLabel != null &&
                    onConfigureCloudAccess != null)
                  ListTile(
                    key: NodesTestKeys.configureCloudAccessFab,
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: Text(cloudAccessActionLabel!),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onConfigureCloudAccess!();
                    },
                  ),
                if (onCreateCloudNode != null)
                  ListTile(
                    key: NodesTestKeys.deployCloudNodeFab,
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: Text(l10n.deployNode),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onCreateCloudNode!();
                    },
                  ),
                if ((cloudAccessActionLabel != null &&
                        onConfigureCloudAccess != null) ||
                    onCreateCloudNode != null)
                  const Divider(height: 1),
                ListTile(
                  key: NodesTestKeys.importProfileFab,
                  leading: const Icon(Icons.lock_open_outlined),
                  title: Text(l10n.importProfile),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onImportProfile();
                  },
                ),
                ListTile(
                  key: NodesTestKeys.createProfileFab,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(l10n.createProfileTooltip),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onCreateProfile();
                  },
                ),
                ListTile(
                  key: NodesTestKeys.addWireguardFab,
                  leading: const Icon(Icons.vpn_lock_outlined),
                  title: const Text('添加 WireGuard / Add WireGuard'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onAddWireguard();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
