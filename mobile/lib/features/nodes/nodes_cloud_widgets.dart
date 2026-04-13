import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import 'nodes_common_widgets.dart';

class NodesCloudInstanceCard extends StatelessWidget {
  final CloudInstance instance;
  final CloudLatencyCheck? latencyCheck;
  final bool isLinked;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback onViewDetails;
  final VoidCallback onDelete;
  final VoidCallback? onUseNode;
  final VoidCallback? onTestLatency;

  const NodesCloudInstanceCard({
    Key? key,
    required this.instance,
    this.latencyCheck,
    required this.isLinked,
    required this.isSelected,
    required this.isConnected,
    required this.onViewDetails,
    required this.onDelete,
    this.onUseNode,
    this.onTestLatency,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isReady =
        instance.isActive && instance.hasIp && instance.nodeInfo != null;
    final canUseNode = !isSelected || !isConnected;
    final isLatencyTesting = latencyCheck?.isTesting == true;
    final primaryLabel = isSelected
        ? (isConnected ? l10n.activeNode : l10n.connect)
        : (isConnected ? l10n.useAndSwitch : l10n.useAndConnect);
    final primaryIcon = isSelected
        ? (isConnected ? Icons.check_circle : Icons.shield)
        : Icons.play_arrow;
    final throughputLabel = _formatThroughput(latencyCheck?.throughputMbps);
    final latencyLabel = isLatencyTesting
        ? l10n.testing
        : throughputLabel != null
            ? throughputLabel
            : latencyCheck?.error != null
                ? l10n.retrySpeedTest
                : l10n.speedTest;
    final latencyDetail = _latencyDetailText(latencyCheck, l10n);

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
                        '${instance.region.toUpperCase()}${instance.hasIp ? ' • ${instance.ipv4}' : ''}',
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
                    if (value == 'details') {
                      onViewDetails();
                      return;
                    }
                    if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) {
                    final menuL10n = AppLocalizations.of(context)!;
                    return [
                      PopupMenuItem(
                        value: 'details',
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                menuL10n.nodeDetails,
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
                                menuL10n.deleteNode,
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
                NodesStatusChip(
                  text: instance.isActive ? l10n.active : l10n.provisioning,
                  color: instance.isActive ? Colors.green : Colors.orange,
                ),
                if (isSelected)
                  NodesStatusChip(
                    text: l10n.inUse,
                    color: Colors.blue,
                  ),
              ],
            ),
            if (isReady) ...[
              SizedBox(height: 14.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  FilledButton.icon(
                    onPressed: canUseNode ? onUseNode : null,
                    icon: Icon(primaryIcon),
                    label: Text(primaryLabel),
                  ),
                  OutlinedButton.icon(
                    onPressed: isLatencyTesting ? null : onTestLatency,
                    icon: isLatencyTesting
                        ? SizedBox(
                            width: 16.w,
                            height: 16.w,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.speed),
                    label: Text(latencyLabel),
                  ),
                ],
              ),
              if (latencyDetail != null) ...[
                SizedBox(height: 10.h),
                Text(
                  latencyDetail,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: latencyCheck?.error == null
                        ? Colors.grey[700]
                        : Colors.orange[800],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String? _latencyDetailText(CloudLatencyCheck? latencyCheck, AppLocalizations l10n) {
    if (latencyCheck == null) {
      return null;
    }
    if (latencyCheck.error != null) {
      return latencyCheck.error;
    }
    final endpointLabel = latencyCheck.endpointLabel;
    if (endpointLabel == null || endpointLabel.isEmpty) {
      return null;
    }
    if (!latencyCheck.isBenchmark) {
      return endpointLabel;
    }
    final sampleCount = latencyCheck.sampleCount;
    final successfulSamples = latencyCheck.successfulSamples;
    if (sampleCount == null || successfulSamples == null || sampleCount <= 0) {
      return _buildBenchmarkDetail(
        l10n: l10n,
        endpointLabel: endpointLabel,
        throughputMbps: latencyCheck.throughputMbps,
        latencyMs: latencyCheck.latencyMs,
      );
    }
    return _buildBenchmarkDetail(
      l10n: l10n,
      endpointLabel: endpointLabel,
      throughputMbps: latencyCheck.throughputMbps,
      latencyMs: latencyCheck.latencyMs,
      sampleCount: sampleCount,
      successfulSamples: successfulSamples,
    );
  }

  String _buildBenchmarkDetail({
    required AppLocalizations l10n,
    required String endpointLabel,
    double? throughputMbps,
    int? latencyMs,
    int? sampleCount,
    int? successfulSamples,
  }) {
    final segments = <String>[endpointLabel];
    if (sampleCount != null && successfulSamples != null && sampleCount > 0) {
      segments.add(l10n.probesStat(successfulSamples, sampleCount));
    }
    final throughputLabel = _formatThroughput(throughputMbps);
    if (throughputLabel != null) {
      segments.add(throughputLabel);
    }
    if (latencyMs != null) {
      segments.add(l10n.msLatency(latencyMs));
    }
    return segments.join(' \u2022 ');
  }

  String? _formatThroughput(double? throughputMbps) {
    if (throughputMbps == null || throughputMbps <= 0) {
      return null;
    }
    if (throughputMbps >= 100) {
      return '${throughputMbps.toStringAsFixed(0)} Mbps';
    }
    if (throughputMbps >= 10) {
      return '${throughputMbps.toStringAsFixed(1)} Mbps';
    }
    return '${throughputMbps.toStringAsFixed(2)} Mbps';
  }
}
