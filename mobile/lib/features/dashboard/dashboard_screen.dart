import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dashboard_provider.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/error_view.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DashboardProvider>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<DashboardProvider>().refreshAll();
            },
          ),
        ],
      ),
      body: Consumer<DashboardProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading && provider.systemInfo == null) {
            return const LoadingIndicator(message: 'Loading dashboard...');
          }

          if (provider.error != null && provider.systemInfo == null) {
            return ErrorView(
              message: provider.error!,
              onRetry: () => provider.refreshAll(),
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.refreshAll(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(16.w),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // System Info Cards
                  if (provider.systemInfo != null) ...[
                    _buildSystemInfoCards(provider.systemInfo!),
                    SizedBox(height: 24.h),
                  ],

                  // Traffic Chart
                  if (provider.trafficHistory.isNotEmpty) ...[
                    _buildTrafficChart(provider),
                    SizedBox(height: 24.h),
                  ],

                  // Quick Stats
                  if (provider.systemInfo != null) ...[
                    _buildQuickStats(provider.systemInfo!),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSystemInfoCards(SystemInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'System Overview',
          style: TextStyle(
            fontSize: 20.sp,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 12.h),
        Row(
          children: [
            Expanded(
              child: _buildInfoCard(
                icon: Icons.memory,
                title: 'Memory',
                value: info.memory.usedFormatted,
                subtitle: '${info.memory.usagePercent.toStringAsFixed(1)}% of ${info.memory.totalFormatted}',
                color: Colors.blue,
                progress: info.memory.usagePercent / 100,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: _buildInfoCard(
                icon: Icons.developer_board,
                title: 'CPU',
                value: info.cpu.usageFormatted,
                subtitle: '${info.cpu.cores} cores',
                color: Colors.green,
                progress: info.cpu.usage / 100,
              ),
            ),
          ],
        ),
        SizedBox(height: 12.h),
        Row(
          children: [
            Expanded(
              child: _buildInfoCard(
                icon: Icons.access_time,
                title: 'Uptime',
                value: info.uptimeFormatted,
                subtitle: info.platform,
                color: Colors.purple,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: _buildInfoCard(
                icon: Icons.info,
                title: 'Version',
                value: info.version,
                subtitle: 'PrivateDeploy',
                color: Colors.orange,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    double? progress,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 24.w),
                SizedBox(width: 8.w),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.sp,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Text(
              value,
              style: TextStyle(
                fontSize: 20.sp,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            SizedBox(height: 4.h),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12.sp,
                color: Colors.grey[600],
              ),
            ),
            if (progress != null) ...[
              SizedBox(height: 12.h),
              ClipRRect(
                borderRadius: BorderRadius.circular(4.r),
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: color.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  minHeight: 6.h,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrafficChart(DashboardProvider provider) {
    final history = provider.trafficHistory;
    if (history.isEmpty) return const SizedBox.shrink();

    // 计算最大值用于 Y 轴
    final maxBytes = history.map((e) => e.totalBytes).reduce((a, b) => a > b ? a : b);
    final maxY = maxBytes * 1.2; // 添加 20% 的上边距

    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Traffic History',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16.h),
            SizedBox(
              height: 200.h,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: maxY / 5,
                    getDrawingHorizontalLine: (value) {
                      return FlLine(
                        color: Colors.grey.withValues(alpha: 0.2),
                        strokeWidth: 1,
                      );
                    },
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: (history.length / 5).ceilToDouble(),
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= history.length) {
                            return const SizedBox.shrink();
                          }
                          final time = history[index].timestamp;
                          return Padding(
                            padding: EdgeInsets.only(top: 8.h),
                            child: Text(
                              '${time.hour}:${time.minute.toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: 10.sp,
                                color: Colors.grey[600],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 45,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            _formatBytesShort(value.toInt()),
                            style: TextStyle(
                              fontSize: 10.sp,
                              color: Colors.grey[600],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  minX: 0,
                  maxX: (history.length - 1).toDouble(),
                  minY: 0,
                  maxY: maxY,
                  lineBarsData: [
                    // Upload line
                    LineChartBarData(
                      spots: history.asMap().entries.map((entry) {
                        return FlSpot(
                          entry.key.toDouble(),
                          entry.value.uploadBytes.toDouble(),
                        );
                      }).toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withValues(alpha: 0.1),
                      ),
                    ),
                    // Download line
                    LineChartBarData(
                      spots: history.asMap().entries.map((entry) {
                        return FlSpot(
                          entry.key.toDouble(),
                          entry.value.downloadBytes.toDouble(),
                        );
                      }).toList(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 2,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.green.withValues(alpha: 0.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16.h),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLegendItem(Colors.blue, 'Upload'),
                SizedBox(width: 24.w),
                _buildLegendItem(Colors.green, 'Download'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 16.w,
          height: 3.h,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2.r),
          ),
        ),
        SizedBox(width: 8.w),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.sp,
            color: Colors.grey[700],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickStats(SystemInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Stats',
          style: TextStyle(
            fontSize: 18.sp,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 12.h),
        Card(
          elevation: 2,
          child: Padding(
            padding: EdgeInsets.all(16.w),
            child: Column(
              children: [
                _buildStatRow('Platform', info.platform),
                const Divider(),
                _buildStatRow('Version', info.version),
                const Divider(),
                _buildStatRow('Memory Total', info.memory.totalFormatted),
                const Divider(),
                _buildStatRow('Memory Free', info.memory.freeFormatted),
                const Divider(),
                _buildStatRow('CPU Cores', '${info.cpu.cores}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14.sp,
              color: Colors.grey[700],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14.sp,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytesShort(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)}K';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)}M';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
    }
  }
}
