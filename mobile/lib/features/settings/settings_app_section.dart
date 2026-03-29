import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import 'app_settings_provider.dart';
import 'settings_routing_rules_dialog.dart';
import 'settings_vpn_diagnostics_screen.dart';
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
          const Divider(height: 1),
          Consumer<AppSettingsProvider>(
            builder: (context, appSettings, _) {
              final routingSettings = appSettings.vpnRoutingSettings;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 8.h),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Routing Mode',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        SizedBox(height: 12.h),
                        SegmentedButton<VpnRoutingMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: VpnRoutingMode.split,
                              label: Text('分流'),
                            ),
                            ButtonSegment(
                              value: VpnRoutingMode.global,
                              label: Text('全局'),
                            ),
                          ],
                          selected: {routingSettings.mode},
                          onSelectionChanged: (selection) {
                            final mode = selection.firstOrNull;
                            if (mode == null) {
                              return;
                            }
                            appSettings.setVpnRoutingMode(mode);
                          },
                        ),
                        SizedBox(height: 8.h),
                        Text(
                          routingSettings.summary,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.monitor_heart_outlined),
                    title: const Text('VPN Diagnostics'),
                    subtitle: const Text('查看当前出口 IP 和最近分流命中'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsVpnDiagnosticsScreen(),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.rule_folder_outlined),
                    title: const Text('Routing Rules'),
                    subtitle: const Text(
                      '默认分流规则 + 可编辑域名和 CIDR 覆盖',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showSettingsRoutingRulesDialog(
                      context: context,
                      settings: routingSettings,
                      onSave: (settings) async {
                        await appSettings.updateVpnRoutingSettings(settings);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Routing rules saved'),
                            ),
                          );
                        }
                      },
                      onReset: () async {
                        await appSettings.resetVpnRoutingSettings();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Routing rules reset to defaults'),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ],
              );
            },
          ),
          const Divider(height: 1),
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
