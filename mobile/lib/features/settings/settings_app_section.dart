import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import 'app_settings_provider.dart';
import 'settings_routing_rules_dialog.dart';
import 'settings_vpn_diagnostics_screen.dart';

class SettingsAppSection extends StatelessWidget {
  const SettingsAppSection({Key? key}) : super(key: key);

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
    return Consumer<AppSettingsProvider>(
      builder: (context, appSettings, _) {
        final routingSettings = appSettings.vpnRoutingSettings;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 12.h),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16.r),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.12),
                ),
              ),
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
                    routingSettings.localizedSummary(l10n),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(height: 12.h),
            ListTile(
              contentPadding: EdgeInsets.symmetric(horizontal: 4.w),
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(l10n.vpnDiagnostics),
              subtitle: Text(l10n.vpnDiagnosticsDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openDiagnostics(context),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.symmetric(horizontal: 4.w),
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
                        content: Text(
                          AppLocalizations.of(context)!.routingRulesSaved,
                        ),
                      ),
                    );
                  }
                },
                onReset: () async {
                  await appSettings.resetVpnRoutingSettings();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AppLocalizations.of(context)!.routingRulesReset,
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
