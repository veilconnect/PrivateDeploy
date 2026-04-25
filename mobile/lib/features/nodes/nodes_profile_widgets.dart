import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../profiles/profile_provider.dart';
import 'nodes_common_widgets.dart';

/// Speed test result for a manual profile.
class ProfileSpeedResult {
  final bool isTesting;
  final double? throughputMbps;
  final int? latencyMs;
  final String? error;

  const ProfileSpeedResult({
    this.isTesting = false,
    this.throughputMbps,
    this.latencyMs,
    this.error,
  });

  const ProfileSpeedResult.testing()
      : isTesting = true,
        throughputMbps = null,
        latencyMs = null,
        error = null;
}

class NodesProfileCard extends StatelessWidget {
  final Profile profile;
  final bool isActive;
  final bool isConnected;
  final String timestampLabel;
  final ProfileSpeedResult? speedResult;
  final VoidCallback onActivate;
  final VoidCallback? onSpeedTest;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const NodesProfileCard({
    Key? key,
    required this.profile,
    required this.isActive,
    this.isConnected = false,
    required this.timestampLabel,
    this.speedResult,
    required this.onActivate,
    this.onSpeedTest,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canUseNode = !isActive || !isConnected;
    final primaryLabel = isActive
        ? (isConnected ? l10n.inUse : l10n.connect)
        : (isConnected ? l10n.useAndSwitch : l10n.useAndConnect);
    final primaryIcon = isActive
        ? (isConnected ? Icons.check_circle : Icons.shield)
        : Icons.play_arrow;

    final isSpeedTesting = speedResult?.isTesting == true;
    final throughput = speedResult?.throughputMbps;
    final speedLabel = isSpeedTesting
        ? l10n.testing
        : throughput != null
            ? _formatThroughput(throughput)
            : speedResult?.error != null
                ? l10n.retrySpeedTest
                : l10n.speedTest;
    final speedDetail = _buildSpeedDetail(l10n);

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFFFCFCFD),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.r),
        side: BorderSide(
          color: isActive
              ? const Color(0xFF1452CC).withValues(alpha: 0.24)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: isActive
                      ? const Color(0xFF1452CC).withValues(alpha: 0.12)
                      : const Color(0xFF667085).withValues(alpha: 0.12),
                  child: Icon(
                    isActive ? Icons.check : Icons.description_outlined,
                    color:
                        isActive ? const Color(0xFF1452CC) : Colors.grey[700],
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: TextStyle(
                          fontSize: 16.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        timestampLabel,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        onEdit();
                        break;
                      case 'delete':
                        onDelete();
                        break;
                    }
                  },
                  itemBuilder: (context) {
                    final menuL10n = AppLocalizations.of(context)!;
                    return [
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            const Icon(Icons.edit),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                menuL10n.rename,
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
                            const Icon(Icons.delete, color: Colors.red),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                menuL10n.delete,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ];
                  },
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                if (isActive)
                  NodesStatusChip(
                    text: isConnected ? l10n.inUse : l10n.selectedRoute,
                    color: const Color(0xFF1452CC),
                  ),
              ],
            ),
            SizedBox(height: 14.h),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canUseNode ? onActivate : null,
                icon: Icon(primaryIcon),
                label: Text(primaryLabel),
              ),
            ),
            SizedBox(height: 8.h),
            Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                OutlinedButton.icon(
                  onPressed: isSpeedTesting ? null : onSpeedTest,
                  icon: isSpeedTesting
                      ? SizedBox(
                          width: 16.w,
                          height: 16.w,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.speed),
                  label: Text(speedLabel),
                ),
                TextButton.icon(
                  onPressed: onView,
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(l10n.viewEditConfig),
                ),
              ],
            ),
            if (speedDetail != null) ...[
              SizedBox(height: 10.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: (speedResult?.error == null
                          ? const Color(0xFF1452CC)
                          : const Color(0xFFF59E0B))
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14.r),
                ),
                child: Text(
                  speedDetail,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: speedResult?.error == null
                        ? Colors.grey[800]
                        : Colors.orange[900],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _buildSpeedDetail(AppLocalizations l10n) {
    if (speedResult == null || speedResult!.isTesting) return null;
    if (speedResult!.error != null && speedResult!.throughputMbps == null) {
      return speedResult!.error;
    }
    final segments = <String>[];
    final tp = speedResult!.throughputMbps;
    if (tp != null && tp > 0) {
      segments.add(_formatThroughput(tp));
    }
    final ms = speedResult!.latencyMs;
    if (ms != null) {
      segments.add(l10n.msLatency(ms));
    }
    return segments.isEmpty ? null : segments.join(' \u00b7 ');
  }

  String _formatThroughput(double mbps) {
    if (mbps >= 100) return '${mbps.toStringAsFixed(0)} Mbps';
    if (mbps >= 10) return '${mbps.toStringAsFixed(1)} Mbps';
    return '${mbps.toStringAsFixed(2)} Mbps';
  }
}
