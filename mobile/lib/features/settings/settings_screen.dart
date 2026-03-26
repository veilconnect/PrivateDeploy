import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/storage/storage_service.dart';
import '../cloud/cloud_provider.dart';

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
                    title: const Text('Cloud Access'),
                    subtitle:
                        const Text('Directly calls Vultr API from this device'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {},
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
                    subtitle: Text(cloud.providerName),
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
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode),
            title: const Text('Dark Mode'),
            value: Theme.of(context).brightness == Brightness.dark,
            onChanged: (_) {
              // Theme toggle would be handled by a theme provider
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear Cache'),
            onTap: () async {
              await StorageService.removeSecure('mobile_cloud_vultr_api_key');
              await StorageService.removeSecure('mobile_cloud_vultr_nodes');
              await StorageService.remove('mobile_cloud_vultr_api_key');
              await StorageService.remove('mobile_cloud_vultr_nodes');
              context.read<CloudProvider>().reset();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cache cleared')),
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
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API Key'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'Paste your Vultr API key',
            labelText: 'API Key',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              cloud.setApiKey(controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
