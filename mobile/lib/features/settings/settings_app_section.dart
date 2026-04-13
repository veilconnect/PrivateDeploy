import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
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

  Future<void> _openDiagnostics(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => const SettingsVpnDiagnosticsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child: Text(l10n.app, style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l10n.theme),
            subtitle: Text(
              Theme.of(context).brightness == Brightness.dark
                  ? l10n.usingSystemDarkTheme
                  : l10n.usingSystemLightTheme,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_lock_outlined),
            title: Text(l10n.vpnStatus),
            subtitle: Consumer<VpnProvider>(
              builder: (context, vpn, _) {
                if (!vpn.isSupported) {
                  return Text(
                      vpn.unsupportedReason ?? l10n.unavailableOnBuild);
                }
                return Text(vpn.isConnected ? l10n.connected : l10n.disconnected);
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
                          l10n.routingMode,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        SizedBox(height: 12.h),
                        SegmentedButton<VpnRoutingMode>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: VpnRoutingMode.split,
                              label: Text(l10n.split),
                            ),
                            ButtonSegment(
                              value: VpnRoutingMode.global,
                              label: Text(l10n.global),
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
                    title: Text(l10n.vpnDiagnostics),
                    subtitle: Text(l10n.vpnDiagnosticsDesc),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openDiagnostics(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.rule_folder_outlined),
                    title: Text(l10n.routingRules),
                    subtitle: Text(l10n.routingRulesDesc),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showSettingsRoutingRulesDialog(
                      context: context,
                      settings: routingSettings,
                      onSave: (settings) async {
                        await appSettings.updateVpnRoutingSettings(settings);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppLocalizations.of(context)!.routingRulesSaved),
                            ),
                          );
                        }
                      },
                      onReset: () async {
                        await appSettings.resetVpnRoutingSettings();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppLocalizations.of(context)!.routingRulesReset),
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
            title: Text(l10n.clearLocalCloudData),
            subtitle: Text(l10n.clearLocalCloudDataDesc),
            onTap: onClearLocalCloudData,
          ),
        ],
      ),
    );
  }
}
