import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import 'app_settings_provider.dart';
import '../vpn/vpn_provider.dart';
import '../vpn/vpn_status_messages.dart';

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
    return Consumer2<VpnProvider, AppSettingsProvider>(
      builder: (context, vpn, appSettings, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              return;
            }
            _popRootRoute();
          },
          child: _buildScaffold(
            context,
            vpn,
            appSettings.vpnRoutingSettings,
          ),
        );
      },
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    VpnProvider vpn,
    VpnRoutingSettings routingSettings,
  ) {
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
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              SizedBox(height: 16.h),
              _DiagnosticsExcludedAppsCard(routingSettings: routingSettings),
            ],
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
    final statusHeadline = switch (vpn.status) {
      VpnStatus.connected => l10n.vpnStatusConnected,
      VpnStatus.connecting => l10n.vpnStatusConnecting,
      VpnStatus.disconnecting => l10n.vpnStatusDisconnecting,
      VpnStatus.disconnected => l10n.vpnStatusDisconnected,
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
              statusHeadline,
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
                l10n.lastUpdated(DateFormat('yyyy-MM-dd HH:mm:ss')
                    .format(vpn.diagnosticsUpdatedAt!)),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (showStatusError) ...[
              SizedBox(height: 8.h),
              Text(
                localizeVpnStatusMessage(vpn.diagnosticsError, l10n),
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
    final value = _diagnosticsEgressValue(vpn, l10n);
    final helpText = _diagnosticsEgressHint(vpn, l10n);

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
                  Text(l10n.currentEgressIp,
                      style: theme.textTheme.titleMedium),
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

class _DiagnosticsExcludedAppsCard extends StatelessWidget {
  const _DiagnosticsExcludedAppsCard({required this.routingSettings});

  final VpnRoutingSettings routingSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final effectivePackages = effectiveAndroidDirectPackages(routingSettings);
    final previewPackages = previewAndroidDirectPackages(routingSettings);
    final remainingCount = effectivePackages.length - previewPackages.length;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.vpnExcludedAppsTitle,
              style: theme.textTheme.titleMedium,
            ),
            SizedBox(height: 8.h),
            Text(
              l10n.vpnExcludedAppsDescription(effectivePackages.length),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (previewPackages.isNotEmpty) ...[
              SizedBox(height: 12.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  ...previewPackages.map(
                    (packageName) => Tooltip(
                      message: packageName,
                      child: Chip(
                        label: Text(
                          displayNameForVpnRoutingPackage(packageName),
                        ),
                      ),
                    ),
                  ),
                  if (remainingCount > 0)
                    Chip(
                      label: Text(l10n.vpnExcludedAppsMore(remainingCount)),
                    ),
                ],
              ),
            ],
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
                (decision) {
                  final accentColor = switch (decision.dnsServerTag) {
                    'dns-remote' => Colors.indigo,
                    'dns-cn' => Colors.teal,
                    'dns-direct' => Colors.blueGrey,
                    'dns-local' => Colors.orange,
                    _ => decision.isDirect ? Colors.teal : Colors.indigo,
                  };
                  final icon = decision.isDnsDecision
                      ? Icons.dns_outlined
                      : (decision.isDirect
                          ? Icons.subdirectory_arrow_left
                          : Icons.cloud_outlined);
                  final pillLabel = decision.isDnsDecision
                      ? l10n.vpnRouteDecisionDns
                      : (decision.isDirect
                          ? l10n.vpnRouteDecisionDirect
                          : l10n.vpnRouteDecisionProxy);
                  final subtitle = decision.isDnsDecision
                      ? '${l10n.vpnRouteDecisionDns} · ${decision.routeLabel} · ${DateFormat('HH:mm:ss').format(decision.timestamp)}'
                      : '${decision.routeLabel} · ${DateFormat('HH:mm:ss').format(decision.timestamp)}';

                  return ListTile(
                    dense: true,
                    leading: Icon(icon, color: accentColor),
                    title: Text(decision.displayTarget),
                    subtitle: Text(subtitle),
                    trailing: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10.w,
                        vertical: 6.h,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        pillLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _diagnosticsEgressValue(VpnProvider vpn, AppLocalizations l10n) {
  if (!vpn.isConnected) {
    return l10n.connectVpnToMeasure;
  }
  final currentIp = vpn.diagnosticsEgressIp;
  if (currentIp != null) {
    return currentIp;
  }
  final lastSeen = vpn.lastKnownEgressIp;
  if (lastSeen != null) {
    return l10n.egressLastSeen(lastSeen);
  }
  if (vpn.isRefreshingDiagnostics) {
    return l10n.refreshing;
  }
  return l10n.egressProbeBusy;
}

String? _diagnosticsEgressHint(VpnProvider vpn, AppLocalizations l10n) {
  if (!vpn.isConnected) {
    return null;
  }
  if (vpn.diagnosticsEgressIp != null) {
    return null;
  }
  if (vpn.lastKnownEgressIp != null) {
    return l10n.egressProbeStillRoutingHint;
  }
  if (vpn.isRefreshingDiagnostics) {
    return l10n.egressProbeHelp;
  }
  final raw = vpn.diagnosticsError;
  if (raw == null) {
    return l10n.egressProbeStillRoutingHint;
  }
  return localizeVpnStatusMessage(raw, l10n);
}
