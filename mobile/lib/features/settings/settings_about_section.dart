import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/app_localizations.dart';

class SettingsAboutSection extends StatelessWidget {
  const SettingsAboutSection({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child:
                Text(l10n.about, style: Theme.of(context).textTheme.titleMedium),
          ),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final versionText = snapshot.hasData
                  ? '${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                  : snapshot.hasError
                      ? l10n.unavailable
                      : l10n.loading;
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.version),
                subtitle: Text(versionText),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(l10n.appTitle),
            subtitle: Text(l10n.multiProtocolTool),
          ),
        ],
      ),
    );
  }
}
