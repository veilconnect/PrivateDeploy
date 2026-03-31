import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_provider.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_cloud_actions.dart';
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
                        'Connection',
                        style: TextStyle(
                          fontSize: 18.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        _statusLabel(vpnProvider.status),
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14.sp,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        selectedProfile != null
                            ? 'Selected node: $selectedProfile'
                            : _connectionHint(cloudProvider),
                        style:
                            TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
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
                    text: 'Up ${stats.uploadFormatted}',
                    color: Colors.blue,
                  ),
                  NodesStatusChip(
                    text: 'Down ${stats.downloadFormatted}',
                    color: Colors.green,
                  ),
                  NodesStatusChip(
                    text: 'Speed ${stats.downloadSpeedFormatted}',
                    color: Colors.purple,
                  ),
                ],
              ),
            ],
            SizedBox(height: 16.h),
            if (!vpnProvider.isSupported)
              NodesInlineInfoCard(
                icon: Icons.info_outline,
                title: 'Native VPN unavailable',
                message: vpnProvider.unsupportedReason ??
                    'This build does not include a usable native VPN runtime.',
              )
            else if (vpnProvider.isLoading)
              const LoadingIndicator(message: 'Processing VPN...')
            else
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
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
                            ? 'Disconnect'
                            : 'Connect',
                      ),
                    ),
                  ),
                  if (vpnProvider.status == VpnStatus.connected) ...[
                    SizedBox(height: 10.h),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: onRestart,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Restart VPN'),
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

String _statusLabel(VpnStatus status) {
  switch (status) {
    case VpnStatus.connected:
      return 'Connected';
    case VpnStatus.connecting:
      return 'Connecting...';
    case VpnStatus.disconnecting:
      return 'Disconnecting...';
    case VpnStatus.disconnected:
      return 'Disconnected';
  }
}

String _connectionHint(CloudProvider cloudProvider) {
  final readyCloudNodes = connectableCloudInstances(cloudProvider);
  if (readyCloudNodes.length == 1) {
    return 'Tap Connect to use your ready cloud node automatically.';
  }
  if (readyCloudNodes.length > 1) {
    return 'Tap Connect to test your ready cloud nodes and use the fastest one automatically, or select a local profile below.';
  }
  if (cloudProvider.instances.isNotEmpty) {
    return 'Cloud nodes are visible, but this device still needs their local credentials before it can connect.';
  }
  return 'Choose a node or local profile below before connecting.';
}
