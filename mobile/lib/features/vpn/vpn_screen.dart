import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'vpn_provider.dart';
import '../profiles/profile_provider.dart';
import '../../shared/widgets/loading_indicator.dart';

class VpnScreen extends StatefulWidget {
  const VpnScreen({Key? key}) : super(key: key);

  @override
  State<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends State<VpnScreen> with TickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VpnProvider>().initialize();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN Control'),
        actions: [
          Consumer<VpnProvider>(
            builder: (context, provider, _) {
              if (!provider.isSupported) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  context.read<VpnProvider>().loadStatus();
                },
              );
            },
          ),
        ],
      ),
      body: Consumer<VpnProvider>(
        builder: (context, provider, _) {
          if (!provider.isSupported) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(24.w),
              child: _buildUnsupportedState(provider),
            );
          }
          return RefreshIndicator(
            onRefresh: () => provider.loadStatus(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(24.w),
              child: Column(
                children: [
                  // Connection Status Card
                  _buildConnectionCard(provider),
                  SizedBox(height: 24.h),

                  // Control Button
                  _buildControlButton(provider),
                  SizedBox(height: 24.h),

                  // Traffic Statistics
                  if (provider.isConnected) ...[
                    _buildTrafficStats(provider),
                    SizedBox(height: 24.h),
                    _buildSpeedStats(provider),
                    SizedBox(height: 24.h),
                    _buildResetButton(provider),
                  ],

                  // Error Message
                  if (provider.error != null)
                    Container(
                      margin: EdgeInsets.only(top: 16.h),
                      padding: EdgeInsets.all(12.w),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error, color: Colors.red),
                          SizedBox(width: 8.w),
                          Expanded(
                            child: Text(
                              provider.error!,
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 14.sp,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildUnsupportedState(VpnProvider provider) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.r),
      ),
      child: Padding(
        padding: EdgeInsets.all(24.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 28.w),
                SizedBox(width: 12.w),
                Expanded(
                  child: Text(
                    'Native VPN unavailable',
                    style: TextStyle(
                      fontSize: 20.sp,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Text(
              provider.unsupportedReason ??
                  'This build does not include a usable native VPN runtime.',
              style: TextStyle(
                fontSize: 14.sp,
                height: 1.5,
                color: Colors.grey[700],
              ),
            ),
            SizedBox(height: 12.h),
            Text(
              'You can still manage profiles and cloud nodes on this device, but native VPN connect/disconnect is disabled for this build.',
              style: TextStyle(
                fontSize: 13.sp,
                height: 1.5,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard(VpnProvider provider) {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (provider.status) {
      case VpnStatus.connected:
        statusColor = Colors.green;
        statusText = 'Connected';
        statusIcon = Icons.check_circle;
        break;
      case VpnStatus.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        statusIcon = Icons.sync;
        break;
      case VpnStatus.disconnecting:
        statusColor = Colors.orange;
        statusText = 'Disconnecting...';
        statusIcon = Icons.sync;
        break;
      default:
        statusColor = Colors.grey;
        statusText = 'Disconnected';
        statusIcon = Icons.cancel;
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.r),
      ),
      child: Container(
        padding: EdgeInsets.all(24.w),
        child: Column(
          children: [
            // Status Indicator with Animation
            Stack(
              alignment: Alignment.center,
              children: [
                if (provider.status == VpnStatus.connected)
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 120.w + (_pulseController.value * 20.w),
                        height: 120.w + (_pulseController.value * 20.w),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor.withValues(
                              alpha: 0.2 - (_pulseController.value * 0.2)),
                        ),
                      );
                    },
                  ),
                Container(
                  width: 120.w,
                  height: 120.w,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.3),
                        blurRadius: 20.r,
                        spreadRadius: 5.r,
                      ),
                    ],
                  ),
                  child: Icon(
                    statusIcon,
                    size: 60.w,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            SizedBox(height: 24.h),

            // Status Text
            Text(
              statusText,
              style: TextStyle(
                fontSize: 24.sp,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),

            if (provider.activeProfile != null) ...[
              SizedBox(height: 8.h),
              Text(
                'Profile: ${provider.activeProfile}',
                style: TextStyle(
                  fontSize: 14.sp,
                  color: Colors.grey[600],
                ),
              ),
            ],

            if (provider.isConnected &&
                provider.stats.connectionTime.inSeconds > 0) ...[
              SizedBox(height: 8.h),
              Text(
                'Connected for ${provider.stats.connectionTimeFormatted}',
                style: TextStyle(
                  fontSize: 14.sp,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton(VpnProvider provider) {
    if (provider.isLoading) {
      return const LoadingIndicator(message: 'Processing...');
    }

    final isConnected = provider.status == VpnStatus.connected;
    final isDisconnected = provider.status == VpnStatus.disconnected;

    return Column(
      children: [
        // Main Connect/Disconnect Button
        SizedBox(
          width: double.infinity,
          height: 56.h,
          child: ElevatedButton(
            onPressed: isDisconnected
                ? () => _handleConnect(provider)
                : isConnected
                    ? () => _handleDisconnect(provider)
                    : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: isConnected ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28.r),
              ),
              elevation: 4,
            ),
            child: Text(
              isConnected ? 'Disconnect' : 'Connect',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),

        // Restart Button (only when connected)
        if (isConnected) ...[
          SizedBox(height: 12.h),
          SizedBox(
            width: double.infinity,
            height: 48.h,
            child: OutlinedButton.icon(
              onPressed: () => _handleRestart(provider),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Restart VPN'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.blue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24.r),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTrafficStats(VpnProvider provider) {
    final stats = provider.stats;

    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Traffic Statistics',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16.h),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.arrow_upward,
                    label: 'Upload',
                    value: stats.uploadFormatted,
                    color: Colors.blue,
                  ),
                ),
                SizedBox(width: 16.w),
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.arrow_downward,
                    label: 'Download',
                    value: stats.downloadFormatted,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16.h),
            _buildStatItem(
              icon: Icons.swap_vert,
              label: 'Total',
              value: stats.totalFormatted,
              color: Colors.purple,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedStats(VpnProvider provider) {
    final stats = provider.stats;

    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current Speed',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16.h),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.arrow_upward,
                    label: 'Upload',
                    value: stats.uploadSpeedFormatted,
                    color: Colors.blue,
                  ),
                ),
                SizedBox(width: 16.w),
                Expanded(
                  child: _buildStatItem(
                    icon: Icons.arrow_downward,
                    label: 'Download',
                    value: stats.downloadSpeedFormatted,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24.w),
          SizedBox(height: 8.h),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.sp,
              color: Colors.grey[600],
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            value,
            style: TextStyle(
              fontSize: 16.sp,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResetButton(VpnProvider provider) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _handleResetStats(provider),
        icon: const Icon(Icons.restore),
        label: const Text('Reset Statistics'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.orange,
        ),
      ),
    );
  }

  String? _validateSingboxConfig(String configJson) {
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) {
        return 'Invalid config: not a JSON object';
      }
      final outbounds = decoded['outbounds'];
      if (outbounds is! List || outbounds.isEmpty) {
        return 'Invalid config: missing or empty "outbounds" section';
      }
      return null;
    } on FormatException {
      return 'Invalid config: not valid JSON';
    } catch (e) {
      return 'Invalid config: $e';
    }
  }

  Future<void> _handleConnect(VpnProvider provider) async {
    final profileProvider = context.read<ProfileProvider>();
    final activeProfile = profileProvider.activeProfile;
    final configJson = profileProvider.getActiveConfigJson();
    if (configJson == null || configJson.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Please create and activate a profile with sing-box config first'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final configError = _validateSingboxConfig(configJson);
    if (configError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(configError),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    final success = await provider.connect(
      configJson: configJson,
      profileName: activeProfile?.name,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'VPN connected successfully'
              : provider.error ?? 'Failed to connect VPN'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _handleDisconnect(VpnProvider provider) async {
    final success = await provider.disconnect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'VPN disconnected successfully'
              : provider.error ?? 'Failed to disconnect VPN'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _handleRestart(VpnProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart VPN'),
        content:
            const Text('Are you sure you want to restart the VPN connection?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restart'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await provider.restart();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'VPN restarted successfully'
                : provider.error ?? 'Failed to restart VPN'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleResetStats(VpnProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Statistics'),
        content: const Text(
            'Are you sure you want to reset all traffic statistics?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await provider.resetStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Statistics reset successfully'
                : provider.error ?? 'Failed to reset statistics'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    }
  }
}
