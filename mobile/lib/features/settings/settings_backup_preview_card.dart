import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_backup.dart';

class SettingsBackupPreviewCard extends StatelessWidget {
  const SettingsBackupPreviewCard({
    super.key,
    required this.preview,
    this.title,
  });

  final CloudBackupPreview preview;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final rows = <({String label, String value})>[
      (label: 'Version', value: preview.version.toString()),
      (label: 'Provider', value: preview.provider),
      (label: 'Node records', value: preview.nodeCount.toString()),
      (
        label: 'API key',
        value: preview.includesApiKey ? 'Included' : 'Not included',
      ),
      (label: 'Exported at', value: preview.exportedAtLabel),
    ];
    final cdn = preview.cdnPreview;
    if (cdn != null) {
      final parts = <String>[];
      if (cdn.includesToken) parts.add('token');
      if (cdn.deploymentCount > 0) {
        parts.add('${cdn.deploymentCount} deployment'
            '${cdn.deploymentCount == 1 ? '' : 's'}');
      }
      if (cdn.customDomainHost.isNotEmpty) {
        parts.add(cdn.customDomainHost);
      }
      rows.add((
        label: 'CDN',
        value: parts.isEmpty ? 'Included' : parts.join(' · '),
      ));
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title!.trim().isNotEmpty) ...[
            Text(title!, style: Theme.of(context).textTheme.titleSmall),
            SizedBox(height: 8.h),
          ],
          for (final row in rows)
            Padding(
              padding: EdgeInsets.only(bottom: 6.h),
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium,
                  children: [
                    TextSpan(
                      text: '${row.label}: ',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    TextSpan(text: row.value),
                  ],
                ),
              ),
            ),
          if (preview.nodeLabels.isNotEmpty) ...[
            SizedBox(height: 4.h),
            Text(
              _buildNodePreviewText(preview.nodeLabels),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  String _buildNodePreviewText(List<String> labels) {
    const maxInlineItems = 3;
    final visible = labels.take(maxInlineItems).join(', ');
    final remaining = labels.length - maxInlineItems;
    if (remaining > 0) {
      return 'Nodes: $visible, +$remaining more';
    }
    return 'Nodes: $visible';
  }
}
