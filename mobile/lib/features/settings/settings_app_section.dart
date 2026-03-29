import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../vpn/vpn_provider.dart';

class SettingsAppSection extends StatelessWidget {
  const SettingsAppSection({
    Key? key,
    required this.onClearLocalCloudData,
  }) : super(key: key);

  final Future<void> Function() onClearLocalCloudData;

  @override
  Widget build(BuildContext context) {
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
                      vpn.unsupportedReason ?? 'Unavailable on this build');
                }
                return Text(vpn.isConnected ? 'Connected' : 'Disconnected');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear Local Cloud Data'),
            subtitle: const Text('Removes saved API key and local node cache'),
            onTap: onClearLocalCloudData,
          ),
        ],
      ),
    );
  }
}
