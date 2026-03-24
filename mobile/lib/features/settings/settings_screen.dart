import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
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
            child: Text('Server', style: Theme.of(context).textTheme.titleMedium),
          ),
          Consumer<CloudProvider>(
            builder: (context, cloud, _) {
              final config = cloud.config;
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('API Endpoint'),
                    subtitle: Text(config?.apiUrl ?? 'Not configured'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showEndpointDialog(context, cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key),
                    title: const Text('API Key'),
                    subtitle: Text(config?.apiKey != null && config!.apiKey.isNotEmpty
                        ? '${config.apiKey.substring(0, 8)}...'
                        : 'Not set'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showApiKeyDialog(context, cloud),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('Cloud Provider'),
                    subtitle: Text(config?.provider ?? 'vultr'),
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
              await StorageService().clearAll();
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
            child: Text('About', style: Theme.of(context).textTheme.titleMedium),
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

  void _showEndpointDialog(BuildContext context, CloudProvider cloud) {
    final controller = TextEditingController(text: cloud.config?.apiUrl ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API Endpoint'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.100:8443',
            labelText: 'Server URL',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              cloud.updateEndpoint(controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              cloud.updateApiKey(controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
