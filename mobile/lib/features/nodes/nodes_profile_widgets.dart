import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../profiles/profile_provider.dart';
import 'nodes_common_widgets.dart';

class NodesProfileCard extends StatelessWidget {
  final Profile profile;
  final bool isActive;
  final String createdAtLabel;
  final VoidCallback onActivate;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const NodesProfileCard({
    Key? key,
    required this.profile,
    required this.isActive,
    required this.createdAtLabel,
    required this.onActivate,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isActive ? Colors.green : Colors.grey,
          child: Icon(
            isActive ? Icons.check : Icons.description,
            color: Colors.white,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                profile.name,
                style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (isActive)
              const NodesStatusChip(
                text: 'ACTIVE',
                color: Colors.green,
              ),
          ],
        ),
        subtitle: Padding(
          padding: EdgeInsets.only(top: 4.h),
          child: Text(
            'Created: $createdAtLabel',
            style: TextStyle(fontSize: 12.sp, color: Colors.grey[600]),
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'activate':
                onActivate();
                break;
              case 'view':
                onView();
                break;
              case 'edit':
                onEdit();
                break;
              case 'delete':
                onDelete();
                break;
            }
          },
          itemBuilder: (context) => [
            if (!isActive)
              const PopupMenuItem(
                value: 'activate',
                child: Row(
                  children: [
                    Icon(Icons.play_arrow),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Use & Connect',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'view',
              child: Row(
                children: [
                  Icon(Icons.visibility),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'View / Edit Config',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Rename',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Delete',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
