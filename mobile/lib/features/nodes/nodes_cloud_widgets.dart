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
    final readinessMessage = _readinessMessage(l10n: l10n, isReady: isReady);
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
    final planLabel = _normalizedPlanLabel(instance.plan);
    final metadataLine = _metadataLine(instance, planLabel);
    final quickPerformanceChips = _quickPerformanceChips(l10n);
    final accentColor = isSelected
        ? const Color(0xFF1452CC)
        : isReady
            ? const Color(0xFF0E9F6E)
            : const Color(0xFFF59E0B);

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.r),
        side: BorderSide(
          color: isSelected
              ? accentColor.withValues(alpha: 0.34)
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
                  backgroundColor: accentColor.withValues(alpha: 0.16),
                  child: Icon(
                    isReady ? Icons.cloud_done : Icons.hourglass_empty,
                    color: accentColor,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              instance.label,
                              style: TextStyle(
                                fontSize: 16.sp,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isLinked) ...[
                            SizedBox(width: 8.w),
                            NodesStatusChip(
                              text: l10n.saved,
                              color: const Color(0xFF475467),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        metadataLine,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: Colors.grey[600],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) {
                    final menuL10n = AppLocalizations.of(context)!;
                    return [
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
                  text: isReady ? l10n.active : l10n.provisioning,
                  color: isReady
                      ? const Color(0xFF0E9F6E)
                      : const Color(0xFFF59E0B),
                ),
                if (isSelected)
                  NodesStatusChip(
                    text: l10n.inUse,
                    color: const Color(0xFF1452CC),
                  ),
                if (planLabel != null)
                  NodesStatusChip(
                    text: planLabel,
                    color: const Color(0xFF475467),
                  ),
                ...quickPerformanceChips,
              ],
            ),
            if (readinessMessage != null) ...[
              SizedBox(height: 10.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14.r),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18.sp,
                      color: Colors.orange[900],
                    ),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(
                        readinessMessage,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: Colors.orange[900],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 8.h),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onViewDetails,
                  icon: const Icon(Icons.info_outline),
                  label: Text(l10n.nodeDetails),
                ),
              ),
            ],
            if (isReady) ...[
              SizedBox(height: 14.h),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: canUseNode ? onUseNode : null,
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
                  TextButton.icon(
                    onPressed: onViewDetails,
                    icon: const Icon(Icons.info_outline),
                    label: Text(l10n.nodeDetails),
                  ),
                ],
              ),
              if (latencyDetail != null) ...[
                SizedBox(height: 10.h),
                Container(
                  width: double.infinity,
                  padding:
                      EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                  decoration: BoxDecoration(
                    color: (latencyCheck?.error == null
                            ? const Color(0xFF1452CC)
                            : const Color(0xFFF59E0B))
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14.r),
                  ),
                  child: Text(
                    latencyDetail,
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: latencyCheck?.error == null
                          ? Colors.grey[800]
                          : Colors.orange[900],
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String? _latencyDetailText(
      CloudLatencyCheck? latencyCheck, AppLocalizations l10n) {
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

  String? _normalizedPlanLabel(String rawPlan) {
    final normalized = rawPlan.trim();
    if (normalized.isEmpty || normalized.toLowerCase() == 'unknown') {
      return null;
    }
    return normalized;
  }

  String _metadataLine(CloudInstance instance, String? planLabel) {
    final segments = <String>[
      _providerLabel(instance.provider),
      instance.region.toUpperCase(),
      if (instance.hasIp) instance.ipv4!,
      if (planLabel != null) planLabel,
    ];
    return segments.join(' \u00b7 ');
  }

  List<Widget> _quickPerformanceChips(AppLocalizations l10n) {
    if (latencyCheck == null ||
        latencyCheck!.isTesting ||
        latencyCheck!.error != null) {
      return const [];
    }

    final chips = <Widget>[];
    final throughputLabel = _formatThroughput(latencyCheck!.throughputMbps);
    if (throughputLabel != null) {
      chips.add(
        NodesStatusChip(
          text: throughputLabel,
          color: const Color(0xFF0F766E),
        ),
      );
    }
    if (latencyCheck!.latencyMs != null) {
      chips.add(
        NodesStatusChip(
          text: l10n.msLatency(latencyCheck!.latencyMs!),
          color: const Color(0xFF7C3AED),
        ),
      );
    }
    return chips;
  }

  String _providerLabel(String providerId) {
    return switch (providerId) {
      'digitalocean' => 'DigitalOcean',
      'vultr' => 'Vultr',
      _ => providerId,
    };
  }

  String? _readinessMessage({
    required AppLocalizations l10n,
    required bool isReady,
  }) {
    if (isReady) {
      return null;
    }
    if (instance.isActive) {
      return l10n.waitingForCredentials;
    }
    return null;
  }
}
