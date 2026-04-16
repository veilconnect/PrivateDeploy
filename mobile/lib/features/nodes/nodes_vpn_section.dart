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

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24.r,
                  backgroundColor: statusColor,
                  child: Icon(
                    _statusIcon(vpnProvider.status),
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.connection,
                        style: TextStyle(
                          fontSize: 18.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        _statusLabel(vpnProvider.status, l10n),
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14.sp,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        selectedProfile ?? _connectionHint(cloudProvider, l10n),
                        style:
                            TextStyle(fontSize: 12.sp, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (vpnProvider.isConnected) ...[
              SizedBox(height: 14.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  NodesStatusChip(
                    text: l10n.upStats(stats.uploadFormatted),
                    color: Colors.blue,
                  ),
                  NodesStatusChip(
                    text: l10n.downStats(stats.downloadFormatted),
                    color: Colors.green,
                  ),
                  NodesStatusChip(
                    text: l10n.speedStats(stats.downloadSpeedFormatted),
                    color: Colors.purple,
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
              )
            else if (vpnProvider.isLoading)
              LoadingIndicator(message: l10n.processingVpn)
            else
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: NodesTestKeys.connectButton,
                      onPressed: vpnProvider.status == VpnStatus.disconnected
                          ? onConnect
                          : vpnProvider.status == VpnStatus.connected
                              ? onDisconnect
                              : null,
                      icon: Icon(
                        vpnProvider.status == VpnStatus.connected
                            ? Icons.power_settings_new
                            : Icons.shield,
                      ),
                      label: Text(
                        vpnProvider.status == VpnStatus.connected
                            ? l10n.disconnect
                            : l10n.connect,
                      ),
                    ),
                  ),
                  if (vpnProvider.status == VpnStatus.connected) ...[
                    SizedBox(height: 10.h),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: NodesTestKeys.restartButton,
                        onPressed: onRestart,
                        icon: const Icon(Icons.restart_alt),
                        label: Text(l10n.restartVpn),
                      ),
                    ),
                  ],
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
