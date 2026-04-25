import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import 'nodes_common_widgets.dart';

class NodesCloudInstanceCard extends StatelessWidget {
  final CloudInstance instance;
  final CloudLatencyCheck? latencyCheck;
  final String? activeEndpointLabel;
  final String? preferredEndpointLabel;
  final List<String> availableEndpointLabels;
  final bool isLinked;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback onViewDetails;
  final VoidCallback onDelete;
  final VoidCallback? onUseNode;
  final VoidCallback? onTestLatency;
  final VoidCallback? onChooseEndpoint;

  const NodesCloudInstanceCard({
    Key? key,
    required this.instance,
    this.latencyCheck,
    this.activeEndpointLabel,
    this.preferredEndpointLabel,
    this.availableEndpointLabels = const [],
    required this.isLinked,
    required this.isSelected,
    required this.isConnected,
    required this.onViewDetails,
    required this.onDelete,
    this.onUseNode,
    this.onTestLatency,
    this.onChooseEndpoint,
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
        ? (isConnected ? l10n.inUse : l10n.connect)
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
    final regionLabel = instance.region.toUpperCase();
    final quickPerformanceChips = _quickPerformanceChips(l10n);
    final normalizedActiveEndpointLabel = activeEndpointLabel?.trim();
    final normalizedPreferredEndpointLabel = preferredEndpointLabel?.trim();
    final protocolLabel =
        (isConnected && normalizedActiveEndpointLabel?.isNotEmpty == true)
            ? normalizedActiveEndpointLabel!
            : (normalizedPreferredEndpointLabel?.isNotEmpty == true)
                ? normalizedPreferredEndpointLabel!
                : (normalizedActiveEndpointLabel?.isNotEmpty == true)
                    ? normalizedActiveEndpointLabel!
                    : l10n.automatic;
    final accentColor = isSelected
        ? const Color(0xFF1452CC)
        : isReady
            ? const Color(0xFF0E9F6E)
            : const Color(0xFFF59E0B);

    return Card(
      margin: EdgeInsets.only(bottom: 6.h),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.r),
        side: BorderSide(
          color: isSelected
              ? accentColor.withValues(alpha: 0.34)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(10.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34.w,
                  height: 34.w,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                  child: Icon(
                    isReady ? Icons.cloud_done : Icons.hourglass_empty,
                    color: accentColor,
                    size: 18.sp,
                  ),
                ),
                SizedBox(width: 8.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instance.label,
                        style: TextStyle(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        regionLabel,
                        style: TextStyle(
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[800],
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        metadataLine,
                        style: TextStyle(
                          fontSize: 10.sp,
                          color: Colors.grey[600],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'details':
                        onViewDetails();
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
                      const PopupMenuDivider(),
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
            SizedBox(height: 8.h),
            Wrap(
              spacing: 6.w,
              runSpacing: 6.h,
              children: [
                if (isSelected)
                  NodesStatusChip(
                    text: isConnected ? l10n.inUse : l10n.selectedRoute,
                    color: const Color(0xFF1452CC),
                  ),
                NodesStatusChip(
                  text: isReady ? l10n.active : l10n.provisioning,
                  color: isReady
                      ? const Color(0xFF0E9F6E)
                      : const Color(0xFFF59E0B),
                ),
                if (isLinked)
                  NodesStatusChip(
                    text: l10n.saved,
                    color: const Color(0xFF475467),
                  ),
                if (planLabel != null)
                  NodesStatusChip(
                    text: planLabel,
                    color: const Color(0xFF475467),
                  ),
                if (availableEndpointLabels.isNotEmpty)
                  ActionChip(
                    avatar: Icon(
                      Icons.tune,
                      size: 14.sp,
                      color: const Color(0xFF1452CC),
                    ),
                    label: Text(
                      protocolLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: onChooseEndpoint,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    labelStyle: TextStyle(
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1452CC),
                    ),
                    side: BorderSide(
                      color: const Color(0xFF1452CC).withValues(alpha: 0.18),
                    ),
                    backgroundColor:
                        const Color(0xFF1452CC).withValues(alpha: 0.08),
                    padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 0),
                  ),
                ...quickPerformanceChips,
              ],
            ),
            if (readinessMessage != null) ...[
              SizedBox(height: 8.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Wrap(
                  spacing: 8.w,
                  runSpacing: 6.h,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16.sp,
                      color: Colors.orange[900],
                    ),
                    Text(
                      readinessMessage,
                      style: TextStyle(
                        fontSize: 11.sp,
                        color: Colors.orange[900],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isReady) ...[
              SizedBox(height: 8.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  FilledButton.icon(
                    onPressed: canUseNode ? onUseNode : null,
                    icon: Icon(primaryIcon, size: 18.sp),
                    label: Text(primaryLabel),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10.w,
                        vertical: 8.h,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: isLatencyTesting ? null : onTestLatency,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.symmetric(
                        horizontal: 10.w,
                        vertical: 8.h,
                      ),
                    ),
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
                SizedBox(height: 8.h),
                Container(
                  width: double.infinity,
                  padding:
                      EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
                  decoration: BoxDecoration(
                    color: (latencyCheck?.error == null
                            ? const Color(0xFF1452CC)
                            : const Color(0xFFF59E0B))
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                  child: Text(
                    latencyDetail,
                    style: TextStyle(
                      fontSize: 11.sp,
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
    final currentEndpointLabel = activeEndpointLabel?.trim();
    if (latencyCheck == null) {
      return currentEndpointLabel?.isNotEmpty == true
          ? currentEndpointLabel
          : null;
    }
    if (latencyCheck.error != null) {
      return latencyCheck.error;
    }
    final endpointLabel =
        (!latencyCheck.isBenchmark && currentEndpointLabel?.isNotEmpty == true)
            ? currentEndpointLabel
            : latencyCheck.endpointLabel;
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
