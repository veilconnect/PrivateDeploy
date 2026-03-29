import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_models.dart';
import '../profiles/profile_provider.dart';

class NodesSectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final int count;

  const NodesSectionHeader({
    Key? key,
    required this.title,
    required this.subtitle,
    required this.count,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 2.h),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12.sp,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14.r),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: Colors.blue[700],
              fontSize: 12.sp,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class NodesInlineInfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const NodesInlineInfoCard({
    Key? key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28.sp, color: Colors.blueGrey),
            SizedBox(height: 12.h),
            Text(
              title,
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6.h),
            Text(
              message,
              style: TextStyle(fontSize: 13.sp, color: Colors.grey[700]),
            ),
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: 14.h),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class NodesStatusChip extends StatelessWidget {
  final String text;
  final MaterialColor color;

  const NodesStatusChip({
    Key? key,
    required this.text,
    required this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color[700],
          fontSize: 10.sp,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class NodesCloudInstanceCard extends StatelessWidget {
  final CloudInstance instance;
  final bool isLinked;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback onViewDetails;
  final VoidCallback onDelete;
  final VoidCallback? onUseNode;

  const NodesCloudInstanceCard({
    Key? key,
    required this.instance,
    required this.isLinked,
    required this.isSelected,
    required this.isConnected,
    required this.onViewDetails,
    required this.onDelete,
    this.onUseNode,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isReady =
        instance.isActive && instance.hasIp && instance.nodeInfo != null;
    final canUseNode = !isSelected || !isConnected;
    final primaryLabel = isSelected
        ? (isConnected ? 'Active Node' : 'Connect')
        : (isConnected ? 'Use & Switch' : 'Use & Connect');
    final primaryIcon = isSelected
        ? (isConnected ? Icons.check_circle : Icons.shield)
        : Icons.play_arrow;

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor:
                      instance.isActive ? Colors.green : Colors.orange,
                  child: Icon(
                    instance.isActive
                        ? Icons.cloud_done
                        : Icons.hourglass_empty,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instance.label,
                        style: TextStyle(
                          fontSize: 16.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        'Status: ${instance.status} • Region: ${instance.region}',
                        style: TextStyle(fontSize: 12.sp),
                      ),
                      if (instance.hasIp)
                        Text(
                          'IP: ${instance.ipv4}',
                          style: TextStyle(fontSize: 12.sp),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'details') {
                      onViewDetails();
                      return;
                    }
                    if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'details',
                      child: Row(
                        children: [
                          Icon(Icons.info_outline),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Node Details',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Delete Node',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                NodesStatusChip(
                  text: instance.isActive ? 'ACTIVE' : 'PROVISIONING',
                  color: instance.isActive ? Colors.green : Colors.orange,
                ),
                if (instance.isActive &&
                    instance.hasIp &&
                    instance.nodeInfo == null)
                  const NodesStatusChip(
                    text: 'LOCAL CREDS MISSING',
                    color: Colors.deepOrange,
                  ),
                if (isLinked)
                  NodesStatusChip(
                    text: isSelected ? 'IN USE' : 'SYNCED',
                    color: isSelected ? Colors.blue : Colors.teal,
                  ),
                if (instance.nodeInfo != null)
                  const NodesStatusChip(
                    text: 'SS / Hy2 / VLESS / Trojan',
                    color: Colors.indigo,
                  ),
              ],
            ),
            if (instance.isActive && instance.hasIp && instance.nodeInfo == null)
              Padding(
                padding: EdgeInsets.only(top: 10.h),
                child: Text(
                  'This server was found in your Vultr account, but this phone does not have its connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.',
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: Colors.grey[700],
                  ),
                ),
              ),
            if (isReady) ...[
              SizedBox(height: 14.h),
              FilledButton.icon(
                onPressed: canUseNode ? onUseNode : null,
                icon: Icon(primaryIcon),
                label: Text(primaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
