import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../vpn/vpn_provider.dart';

class SettingsVpnDiagnosticsScreen extends StatefulWidget {
  const SettingsVpnDiagnosticsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsVpnDiagnosticsScreen> createState() =>
      _SettingsVpnDiagnosticsScreenState();
}

class _SettingsVpnDiagnosticsScreenState
    extends State<SettingsVpnDiagnosticsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.read<VpnProvider>().refreshDiagnostics();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnProvider>(
      builder: (context, vpn, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('VPN Diagnostics'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: vpn.isRefreshingDiagnostics
                    ? null
                    : () => vpn.refreshDiagnostics(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: vpn.refreshDiagnostics,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(16.w),
              children: [
                _DiagnosticsStatusCard(vpn: vpn),
                SizedBox(height: 16.h),
                _DiagnosticsEgressCard(vpn: vpn),
                SizedBox(height: 16.h),
                _DiagnosticsDecisionCard(vpn: vpn),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiagnosticsStatusCard extends StatelessWidget {
  const _DiagnosticsStatusCard({required this.vpn});

  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = switch (vpn.status) {
      VpnStatus.connected => 'VPN 已连接，下面的数据来自当前活跃会话',
      VpnStatus.connecting => 'VPN 正在建立连接，诊断结果可能会变化',
      VpnStatus.disconnecting => 'VPN 正在断开，诊断结果可能已过期',
      VpnStatus.disconnected => 'VPN 未连接，只显示最近一次会话的规则命中',
    };

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session', style: theme.textTheme.titleMedium),
            SizedBox(height: 8.h),
            Text(
              vpn.status.name.toUpperCase(),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: vpn.isConnected ? Colors.green : Colors.orange,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8.h),
            Text(subtitle),
            if (vpn.diagnosticsUpdatedAt != null) ...[
              SizedBox(height: 8.h),
              Text(
                'Last updated: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(vpn.diagnosticsUpdatedAt!)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (vpn.diagnosticsError != null) ...[
              SizedBox(height: 8.h),
              Text(
                vpn.diagnosticsError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsEgressCard extends StatelessWidget {
  const _DiagnosticsEgressCard({required this.vpn});

  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = switch ((vpn.isConnected, vpn.isRefreshingDiagnostics,
        vpn.diagnosticsEgressIp)) {
      (false, _, _) => 'Connect VPN to measure current egress IP',
      (true, true, null) => 'Refreshing...',
      (true, _, String ip) => ip,
      _ => 'Unavailable',
    };

    return Card(
      child: ListTile(
        leading: const Icon(Icons.public_outlined),
        title: const Text('Current Egress IP'),
        subtitle: Text(
          value,
          style: theme.textTheme.titleMedium,
        ),
      ),
    );
  }
}

class _DiagnosticsDecisionCard extends StatelessWidget {
  const _DiagnosticsDecisionCard({required this.vpn});

  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decisions = vpn.recentRouteDecisions;

    return Card(
      child: Padding(
        padding: EdgeInsets.only(top: 12.h, bottom: 4.h),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.w),
              child: Text(
                'Recent Routing Decisions',
                style: theme.textTheme.titleMedium,
              ),
            ),
            SizedBox(height: 8.h),
            if (decisions.isEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 12.h),
                child: Text(
                  'No routing decisions yet. Browse a few websites, then refresh this page.',
                ),
              )
            else
              ...decisions.map(
                (decision) => ListTile(
                  dense: true,
                  leading: Icon(
                    decision.isDirect
                        ? Icons.subdirectory_arrow_left
                        : Icons.cloud_outlined,
                    color: decision.isDirect ? Colors.teal : Colors.indigo,
                  ),
                  title: Text(decision.displayTarget),
                  subtitle: Text(
                    '${decision.routeLabel} · ${DateFormat('HH:mm:ss').format(decision.timestamp)}',
                  ),
                  trailing: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                    decoration: BoxDecoration(
                      color: decision.isDirect
                          ? Colors.teal.withValues(alpha: 0.12)
                          : Colors.indigo.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      decision.typeLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: decision.isDirect ? Colors.teal : Colors.indigo,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
