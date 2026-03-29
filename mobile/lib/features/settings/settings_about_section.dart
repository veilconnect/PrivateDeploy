import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsAboutSection extends StatelessWidget {
  const SettingsAboutSection({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16.w),
            child:
                Text('About', style: Theme.of(context).textTheme.titleMedium),
          ),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final versionText = snapshot.hasData
                  ? '${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                  : snapshot.hasError
                      ? 'Unavailable'
                      : 'Loading...';
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Version'),
                subtitle: Text(versionText),
              );
            },
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
}
