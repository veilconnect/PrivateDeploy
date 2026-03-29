import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_models.dart';

Future<bool> showNodesDeleteConfirmationDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

Future<CloudInstance?> showNodesCloudNodePickerSheet(
  BuildContext context,
  List<CloudInstance> candidates,
) {
  return showModalBottomSheet<CloudInstance>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose a cloud node',
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 6.h),
              Text(
                'Connect needs one active node. Pick which cloud node to use now.',
                style: TextStyle(
                  fontSize: 13.sp,
                  color: Colors.grey[700],
                ),
              ),
              SizedBox(height: 12.h),
              ...candidates.map(
                (instance) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_done, color: Colors.green),
                  title: Text(instance.label),
                  subtitle: Text(
                    '${instance.region}${instance.ipv4 != null ? ' • ${instance.ipv4}' : ''}',
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(instance),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
