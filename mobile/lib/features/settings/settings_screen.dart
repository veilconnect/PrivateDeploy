import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../cloud/cloud_provider.dart';
import '../vpn/vpn_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.all(16.w),
        children: [
          _buildServerSection(context),
          SizedBox(height: 16.h),
          _buildAppSection(context),
          SizedBox(height: 16.h),
          _buildAboutSection(context),
        ],
      ),
    );
  }

  Widget _buildServerSection(BuildContext context) {
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
              final maskApiKey = cloud.apiKey;
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Standalone Cloud Access'),
                    subtitle:
                        const Text('This device directly calls the Vultr API'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key),
                    title: const Text('API Key'),
                    subtitle: Text(maskApiKey != null && maskApiKey.isNotEmpty
                        ? '${maskApiKey.substring(0, 8)}...'
                        : 'Not set'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showApiKeyDialog(context, cloud),
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
                    onTap: () => _showBackupExportDialog(context, cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.restore_outlined),
                    title: const Text('Restore Cloud Backup'),
                    subtitle: const Text(
                      'Paste a backup JSON to restore API key and nodes',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showBackupImportDialog(context, cloud),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAppSection(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child: Text('App', style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme'),
            subtitle: Text(
              Theme.of(context).brightness == Brightness.dark
                  ? 'Using system dark theme'
                  : 'Using system light theme',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_lock_outlined),
            title: const Text('VPN Status'),
            subtitle: Consumer<VpnProvider>(
              builder: (context, vpn, _) {
                if (!vpn.isSupported) {
                  return Text(
                    vpn.unsupportedReason ?? 'Unavailable on this build',
                  );
                }
                return Text(vpn.isConnected ? 'Connected' : 'Disconnected');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear Local Cloud Data'),
            subtitle: const Text('Removes saved API key and local node cache'),
            onTap: () async {
              final cloud = context.read<CloudProvider>();
              await cloud.clearLocalCloudData();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Local cloud data cleared')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child:
                Text('About', style: Theme.of(context).textTheme.titleMedium),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('1.10.1'),
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('PrivateDeploy'),
            subtitle: Text('Multi-protocol proxy deployment tool'),
          ),
        ],
      ),
    );
  }

  void _showApiKeyDialog(BuildContext context, CloudProvider cloud) {
    final controller = TextEditingController(text: cloud.apiKey ?? '');
    var saving = false;
    String? dialogError;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('API Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                enabled: !saving,
                decoration: InputDecoration(
                  hintText: 'Paste your Vultr API key',
                  labelText: 'API Key',
                  errorText: dialogError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setState(() {
                        saving = true;
                        dialogError = null;
                      });

                      final success = await cloud.setApiKey(controller.text.trim());
                      if (!ctx.mounted) {
                        return;
                      }

                      if (success) {
                        await cloud.loadInstances(notify: false);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('API key saved and verified'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } else {
                        setState(() {
                          saving = false;
                          dialogError = cloud.error ?? 'Failed to save API key';
                        });
                      }
                    },
              child: saving
                  ? const Text('Verifying...')
                  : const Text('Verify & Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBackupExportDialog(
    BuildContext context,
    CloudProvider cloud,
  ) async {
    final payload = await cloud.exportBackupJson();
    await Clipboard.setData(ClipboardData(text: payload));

    if (!context.mounted) {
      return;
    }

    final controller = TextEditingController(text: payload);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cloud Backup Copied'),
        content: SizedBox(
          width: 520.w,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This JSON has already been copied to your clipboard. Store it safely because it includes your Vultr API key.',
              ),
              SizedBox(height: 12.h),
              TextField(
                controller: controller,
                readOnly: true,
                maxLines: 12,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: payload));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Backup copied again')),
                );
              }
            },
            child: const Text('Copy Again'),
          ),
        ],
      ),
    );
  }

  Future<void> _showBackupImportDialog(
    BuildContext context,
    CloudProvider cloud,
  ) async {
    final clipboard = await Clipboard.getData('text/plain');
    final controller = TextEditingController(text: clipboard?.text ?? '');
    String? dialogError;
    var restoring = false;

    if (!context.mounted) {
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Restore Cloud Backup'),
          content: SizedBox(
            width: 520.w,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Paste a backup JSON exported from this app. If it includes an API key, the current key will be replaced.',
                ),
                SizedBox(height: 12.h),
                TextField(
                  controller: controller,
                  minLines: 10,
                  maxLines: 14,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: 'Paste cloud backup JSON here',
                    errorText: dialogError,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: restoring ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: restoring
                  ? null
                  : () async {
                      final latest = await Clipboard.getData('text/plain');
                      setState(() {
                        controller.text = latest?.text ?? '';
                        dialogError = null;
                      });
                    },
              child: const Text('Paste Clipboard'),
            ),
            FilledButton(
              onPressed: restoring
                  ? null
                  : () async {
                      final raw = controller.text.trim();
                      if (raw.isEmpty) {
                        setState(() {
                          dialogError = 'Backup JSON cannot be empty';
                        });
                        return;
                      }

                      setState(() {
                        restoring = true;
                        dialogError = null;
                      });

                      try {
                        await cloud.importBackupJson(raw);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Cloud backup restored'),
                            ),
                          );
                        }
                      } catch (e) {
                        setState(() {
                          dialogError = e.toString().replaceFirst('Exception: ', '');
                          restoring = false;
                        });
                      }
                    },
              child: restoring
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Restore'),
            ),
          ],
        ),
      ),
    );
  }
}
