import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_provider.dart';

Future<void> showSettingsBackupExportDialog({
  required BuildContext context,
  required CloudProvider cloud,
}) async {
  final payload = await cloud.exportBackupJson();
  await Clipboard.setData(ClipboardData(text: payload));

  if (!context.mounted) {
    return;
  }

  await showDialog(
    context: context,
    builder: (_) => _SettingsBackupExportDialog(payload: payload),
  );
}

class _SettingsBackupExportDialog extends StatelessWidget {
  const _SettingsBackupExportDialog({required this.payload});

  final String payload;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12.w),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: SelectableText(payload),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: payload));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Backup copied again')),
              );
            }
          },
          child: const Text('Copy Again'),
        ),
      ],
    );
  }
}
