import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_provider.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_test_keys.dart';
import 'nodes_widgets.dart';

class NodesVpnSection extends StatelessWidget {
  final VpnProvider vpnProvider;
  final ProfileProvider profileProvider;
  final CloudProvider cloudProvider;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRestart;

  const NodesVpnSection({
    Key? key,
    required this.vpnProvider,
    required this.profileProvider,
    required this.cloudProvider,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRestart,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusColor = _statusColor(vpnProvider.status);
    final selectedProfile = profileProvider.activeProfile?.name;
    final stats = vpnProvider.stats;
    final readyCloudNodes = connectableCloudInstances(cloudProvider);
    final allCloudNodes = cloudProvider.allInstances.length;
    final profileValue = selectedProfile ?? l10n.noNodeSelected;
    final profileHint = selectedProfile == null
        ? _connectionHint(cloudProvider, l10n)
        : _statusLabel(vpnProvider.status, l10n);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 54.w,
                  height: 54.w,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        statusColor,
                        statusColor.withValues(alpha: 0.72),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18.r),
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.24),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Icon(
                    _statusIcon(vpnProvider.status),
                    color: Colors.white,
                    size: 28.sp,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8.w,
                        runSpacing: 8.h,
                        children: [
                          NodesStatusChip(
                            text: _statusLabel(vpnProvider.status, l10n),
                            color: statusColor,
                          ),
                          NodesStatusChip(
                            text: cloudProvider.providerId.displayName,
                            color: const Color(0xFF155EEF),
                          ),
                        ],
                      ),
                      SizedBox(height: 10.h),
                      Text(
                        profileValue,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 21.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 6.h),
                      Text(
                        profileHint,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: Colors.grey[700],
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 16.h),
            LayoutBuilder(
              builder: (context, constraints) {
                final tileWidth = (constraints.maxWidth - 10.w) / 2;
                return Wrap(
                  spacing: 10.w,
                  runSpacing: 10.h,
                  children: [
                    SizedBox(
                      width: tileWidth,
                      child: NodesMetricTile(
                        icon: Icons.hub_outlined,
                        label: l10n.cloudNodes,
                        value: '$readyCloudNodes.length / $allCloudNodes',
                        hint: cloudProvider.providerId.displayName,
                        color: const Color(0xFF1452CC),
                      ),
                    ),
                    SizedBox(
                      width: tileWidth,
                      child: NodesMetricTile(
                        icon: Icons.route,
                        label: l10n.activeNode,
                        value: profileValue,
                        hint: _statusLabel(vpnProvider.status, l10n),
                        color: statusColor,
                      ),
                    ),
                  ],
                );
              },
            ),
            if (vpnProvider.isConnected) ...[
              SizedBox(height: 14.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  NodesStatusChip(
                    text: l10n.speedStats(stats.downloadSpeedFormatted),
                    color: const Color(0xFF7C3AED),
                  ),
                  NodesStatusChip(
                    text: l10n.downStats(stats.downloadFormatted),
                    color: const Color(0xFF0E9F6E),
                  ),
                  NodesStatusChip(
                    text: l10n.upStats(stats.uploadFormatted),
                    color: const Color(0xFF1452CC),
                  ),
                ],
              ),
            ],
            SizedBox(height: 16.h),
            if (!vpnProvider.isSupported)
              NodesInlineInfoCard(
                icon: Icons.info_outline,
                title: l10n.nativeVpnUnavailable,
                message: vpnProvider.unsupportedReason ??
                    l10n.nativeVpnUnavailableMessage,
                accentColor: Colors.orange,
              )
            else if (vpnProvider.isLoading)
              LoadingIndicator(message: l10n.processingVpn)
            else
              Column(
                children: [
                  if (vpnProvider.status == VpnStatus.connected)
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: FilledButton.icon(
                            key: NodesTestKeys.connectButton,
                            onPressed: onDisconnect,
                            icon: const Icon(Icons.power_settings_new),
                            label: Text(l10n.disconnect),
                          ),
                        ),
                        SizedBox(width: 10.w),
                        Expanded(
                          flex: 2,
                          child: OutlinedButton.icon(
                            key: NodesTestKeys.restartButton,
                            onPressed: onRestart,
                            icon: const Icon(Icons.restart_alt),
                            label: Text(l10n.restartVpn),
                          ),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: NodesTestKeys.connectButton,
                        onPressed: vpnProvider.status == VpnStatus.disconnected
                            ? onConnect
                            : null,
                        icon: const Icon(Icons.shield),
                        label: Text(l10n.connect),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

Color _statusColor(VpnStatus status) {
  switch (status) {
    case VpnStatus.connected:
      return Colors.green;
    case VpnStatus.connecting:
    case VpnStatus.disconnecting:
      return Colors.orange;
    case VpnStatus.disconnected:
      return Colors.grey;
  }
}

IconData _statusIcon(VpnStatus status) {
  switch (status) {
    case VpnStatus.connected:
      return Icons.check_circle;
    case VpnStatus.connecting:
    case VpnStatus.disconnecting:
      return Icons.sync;
    case VpnStatus.disconnected:
      return Icons.cancel;
  }
}

String _statusLabel(VpnStatus status, AppLocalizations l10n) {
  switch (status) {
    case VpnStatus.connected:
      return l10n.connected;
    case VpnStatus.connecting:
      return l10n.connecting;
    case VpnStatus.disconnecting:
      return l10n.disconnecting;
    case VpnStatus.disconnected:
      return l10n.disconnected;
  }
}

String _connectionHint(CloudProvider cloudProvider, AppLocalizations l10n) {
  final readyCloudNodes = connectableCloudInstances(cloudProvider);
  if (readyCloudNodes.isNotEmpty) {
    return l10n.tapConnectHint;
  }
  if (cloudProvider.allInstances.isNotEmpty) {
    return l10n.waitingForCredentials;
  }
  return l10n.noNodeSelected;
}
