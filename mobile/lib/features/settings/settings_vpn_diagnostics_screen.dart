import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../vpn/vpn_provider.dart';

class SettingsVpnDiagnosticsScreen extends StatefulWidget {
  const SettingsVpnDiagnosticsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsVpnDiagnosticsScreen> createState() =>
      _SettingsVpnDiagnosticsScreenState();
}

class _SettingsVpnDiagnosticsScreenState
    extends State<SettingsVpnDiagnosticsScreen> {
  VpnProvider? _vpnProvider;

  Future<void> _popRootRoute() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    await Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    _vpnProvider = context.read<VpnProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final vpnProvider = _vpnProvider;
      if (vpnProvider == null) {
        return;
      }
      unawaited(vpnProvider.activateDiagnosticsSession());
      unawaited(vpnProvider.refreshDiagnostics());
    });
  }

  @override
  void dispose() {
    final vpnProvider = _vpnProvider;
    if (vpnProvider != null) {
      unawaited(vpnProvider.deactivateDiagnosticsSession());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnProvider>(
      builder: (context, vpn, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              return;
            }
            _popRootRoute();
          },
          child: _buildScaffold(context, vpn),
        );
      },
    );
  }

  Widget _buildScaffold(BuildContext context, VpnProvider vpn) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.back,
          icon: const Icon(Icons.arrow_back),
          onPressed: _popRootRoute,
        ),
        title: Text(l10n.vpnDiagnosticsTitle),
        actions: [
          IconButton(
            tooltip: l10n.refresh,
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
  }
}

class _DiagnosticsStatusCard extends StatelessWidget {
  const _DiagnosticsStatusCard({required this.vpn});

  final VpnProvider vpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final showStatusError = vpn.diagnosticsError != null && !vpn.isConnected;
    final subtitle = switch (vpn.status) {
      VpnStatus.connected => l10n.vpnConnectedDiag,
      VpnStatus.connecting => l10n.vpnConnectingDiag,
      VpnStatus.disconnecting => l10n.vpnDisconnectingDiag,
      VpnStatus.disconnected => l10n.vpnDisconnectedDiag,
    };

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.session, style: theme.textTheme.titleMedium),
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
                l10n.lastUpdated(DateFormat('yyyy-MM-dd HH:mm:ss').format(vpn.diagnosticsUpdatedAt!)),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (showStatusError) ...[
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
    final l10n = AppLocalizations.of(context)!;
    final value = switch ((
      vpn.isConnected,
      vpn.isRefreshingDiagnostics,
      vpn.diagnosticsEgressIp,
      vpn.diagnosticsError
    )) {
      (false, _, _, _) => l10n.connectVpnToMeasure,
      (true, true, null, _) => l10n.refreshing,
      (true, _, String ip, _) => ip,
      (true, _, null, String _) => l10n.probeUnavailable,
      _ => l10n.unavailable,
    };
    final helpText = switch ((
      vpn.isConnected,
      vpn.isRefreshingDiagnostics,
      vpn.diagnosticsEgressIp,
      vpn.diagnosticsError
    )) {
      (true, false, null, String error) => error,
      (true, true, null, _) => l10n.egressProbeHelp,
      _ => null,
    };

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Icon(Icons.public_outlined),
            ),
            SizedBox(width: 16.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.currentEgressIp, style: theme.textTheme.titleMedium),
                  SizedBox(height: 6.h),
                  Text(
                    value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (helpText != null) ...[
                    SizedBox(height: 8.h),
                    Text(
                      helpText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
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
    final l10n = AppLocalizations.of(context)!;
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
                l10n.recentRoutingDecisions,
                style: theme.textTheme.titleMedium,
              ),
            ),
            SizedBox(height: 8.h),
            if (decisions.isEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 12.h),
                child: Text(l10n.noRoutingDecisionsYet),
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
                    padding:
                        EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
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
