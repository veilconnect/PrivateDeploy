import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cdn/cdn_settings_screen.dart';
import '../help/cellular_help_screen.dart';

class SettingsHelpSection extends StatelessWidget {
  const SettingsHelpSection({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child: Text(
              l10n.help,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.signal_cellular_alt_outlined),
            title: Text(l10n.cellularHelpTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CellularHelpScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l10n.cdnAccelerationTitle),
            subtitle: Text(
              l10n.cdnAccelerationSubtitle,
              style: TextStyle(fontSize: 12.sp),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CdnSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
