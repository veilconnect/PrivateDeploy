import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../cloud/cloud_models.dart';
import 'nodes_common_widgets.dart';

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
