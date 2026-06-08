import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';

Future<bool> showNodesConfirmationDialog({
  required BuildContext context,
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  Color? confirmColor,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(cancelLabel ?? l10n.cancel),
            ),
            ElevatedButton(
              style: confirmColor == null
                  ? null
                  : ElevatedButton.styleFrom(
                      backgroundColor: confirmColor,
                      foregroundColor: Colors.white,
                    ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel ?? l10n.continue_),
            ),
          ],
        ),
      ) ??
      false;
}

Future<bool> showNodesDeleteConfirmationDialog({
  required BuildContext context,
  required String title,
  required String message,
  String? confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return showNodesConfirmationDialog(
    context: context,
    title: title,
    message: message,
    confirmLabel: confirmLabel ?? l10n.delete,
    confirmColor: Colors.red,
  );
}

Future<CloudInstance?> showNodesCloudNodePickerSheet(
  BuildContext context,
  List<CloudInstance> candidates,
) {
  return showModalBottomSheet<CloudInstance>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final l10n = AppLocalizations.of(sheetContext)!;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.chooseCloudNode,
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 6.h),
              Text(
                l10n.chooseCloudNodeDesc,
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
