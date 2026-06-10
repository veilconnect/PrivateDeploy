import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../help/cellular_help_screen.dart';
import '../profiles/profile_provider.dart';
import '../vpn/vpn_provider.dart';
import '../vpn/vpn_status_messages.dart';
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
  final VoidCallback onConfigureApiKey;
  final VoidCallback onImportProfile;
  final VoidCallback onCreateCloudNode;
  final VoidCallback onRefreshRoutes;
  final bool showSetupShortcuts;

  /// Whether the *proxy* (翻墙 node) is the active connection. When null the
  /// card falls back to the raw tunnel state. When the tunnel is up carrying
  /// only the intranet WireGuard overlay (proxy disconnected), pass `false` so
  /// the card shows the proxy as disconnected and offers Connect.
  final bool? proxyConnected;

  const NodesVpnSection({
    Key? key,
    required this.vpnProvider,
    required this.profileProvider,
    required this.cloudProvider,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRestart,
    required this.onConfigureApiKey,
    required this.onImportProfile,
    required this.onCreateCloudNode,
    required this.onRefreshRoutes,
    this.showSetupShortcuts = true,
    this.proxyConnected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDegraded = vpnProvider.isDegraded;
    // The proxy (翻墙) connection state, which can differ from the raw tunnel
    // state: the tunnel may be up carrying only the intranet WireGuard overlay.
    final proxyUp = proxyConnected ?? vpnProvider.isConnected;
    final effStatus = proxyConnected == null
        ? vpnProvider.status
        : (proxyConnected! ? vpnProvider.status : VpnStatus.disconnected);
    final statusColor = _statusColor(effStatus, degraded: isDegraded);
    final selectedProfile = profileProvider.activeProfile;
    final stats = vpnProvider.stats;
    final readyCloudNodes = connectableCloudInstances(cloudProvider);
    final savedProfileCount = profileProvider.profiles
        .where((profile) => !isCloudManagedProfile(profile))
        .length;
    final cloudRouteCount = availableCloudRouteCount(
      readyCloudNodes: readyCloudNodes,
      profiles: profileProvider.profiles,
      selectedProfile: selectedProfile,
    );
    final availableRouteCount = cloudRouteCount + savedProfileCount;
    final profileValue = selectedProfile?.name ?? l10n.disconnected;
    final profileHint = _connectionHeaderHint(
      l10n: l10n,
      vpnProvider: vpnProvider,
      cloudProvider: cloudProvider,
      selectedProfile: selectedProfile,
      savedProfileCount: savedProfileCount,
      readyCloudNodeCount: cloudRouteCount,
    );
    final latestDecision = vpnProvider.recentRouteDecisions.isNotEmpty
        ? vpnProvider.recentRouteDecisions.first
        : null;

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
                    _statusIcon(effStatus, degraded: isDegraded),
                    color: Colors.white,
                    size: 28.sp,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      NodesStatusChip(
                        text: _statusLabel(effStatus, l10n,
                            degraded: isDegraded),
                        color: statusColor,
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
            if (!proxyUp)
              NodesMetricTile(
                icon: Icons.hub_outlined,
                label: l10n.availableRoutes,
                value: '$availableRouteCount',
                hint: _availableRoutesHint(
                  l10n: l10n,
                  readyCloudNodeCount: cloudRouteCount,
                  savedProfileCount: savedProfileCount,
                ),
                color: const Color(0xFF1452CC),
              )
            else
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: NodesMetricTile(
                      icon: Icons.timer_outlined,
                      label: l10n.session,
                      value: stats.connectionTimeFormatted,
                      hint:
                          '${l10n.downStats(stats.downloadFormatted)} · ${l10n.upStats(stats.uploadFormatted)}',
                      color: const Color(0xFF7C3AED),
                    ),
                  ),
                  SizedBox(height: 10.h),
                  SizedBox(
                    width: double.infinity,
                    child: NodesMetricTile(
                      icon: Icons.public_outlined,
                      label: l10n.currentEgressIp,
                      value: _egressValue(vpnProvider, l10n),
                      hint: _egressHint(vpnProvider, cloudProvider, l10n),
                      color: const Color(0xFF155EEF),
                    ),
                  ),
                ],
              ),
            if (proxyUp &&
                _hasConnectionDetails(vpnProvider)) ...[
              SizedBox(height: 12.h),
              _ConnectionDetailsTile(
                vpnProvider: vpnProvider,
                latestDecision: latestDecision,
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (effStatus == VpnStatus.connected) ...[
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: NodesTestKeys.connectButton,
                            onPressed: onDisconnect,
                            icon: const Icon(Icons.power_settings_new),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.disconnect,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 10.w),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            key: NodesTestKeys.restartButton,
                            onPressed: onRestart,
                            icon: const Icon(Icons.restart_alt),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.restartVpn,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: NodesTestKeys.connectButton,
                        onPressed: effStatus == VpnStatus.disconnected
                            ? onConnect
                            : null,
                        icon: Icon(
                          effStatus == VpnStatus.disconnected &&
                                  vpnProvider.error != null
                              ? Icons.refresh
                              : Icons.shield,
                        ),
                        label: Text(
                          effStatus == VpnStatus.disconnected &&
                                  vpnProvider.error != null
                              ? l10n.retryConnect
                              : l10n.connect,
                        ),
                      ),
                    ),
                  if (vpnProvider.error != null) ...[
                    SizedBox(height: 10.h),
                    KeyedSubtree(
                      key: NodesTestKeys.vpnNoticeCard,
                      child: NodesInlineBanner(
                        icon: Icons.error_outline,
                        title: l10n.vpnNotice,
                        message: _sanitizeVpnErrorForDisplay(
                          localizeVpnStatusMessage(vpnProvider.error, l10n),
                        ),
                        // Only the UpstreamDegraded canonical message has a
                        // self-explanatory "Why?" deep-link — generic sing-box
                        // errors stay button-less so we don't promise users an
                        // explanation that doesn't apply to their case.
                        secondaryLabel: vpnProvider.error ==
                                VpnProvider.tunnelUpstreamDegradedMessage
                            ? l10n.cellularHelpAction
                            : null,
                        onSecondary: vpnProvider.error ==
                                VpnProvider.tunnelUpstreamDegradedMessage
                            ? () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const CellularHelpScreen(),
                                  ),
                                )
                            : null,
                        accentColor: Colors.orange,
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

bool _hasConnectionDetails(VpnProvider vpnProvider) {
  return vpnProvider.recentRouteDecisions.isNotEmpty ||
      vpnProvider.stats.uploadBytes > 0 ||
      vpnProvider.stats.downloadBytes > 0;
}

/// Strips embedded JSON / multi-line config bodies from a raw VPN error so
/// secrets like passwords or UUIDs are never echoed into the UI banner.
/// Keeps only the first informative line and caps the length.
String _sanitizeVpnErrorForDisplay(String raw) {
  const maxLen = 200;
  // Drop everything after the first newline — sing-box parser errors prefix
  // a one-line summary and then dump the whole config body.
  var firstLine = raw.split(RegExp(r'[\r\n]')).first.trim();
  // Defensive: if the first line itself contains an inline config dump (e.g.
  // "... at character N of {...}"), trim at the first opening brace.
  final braceIdx = firstLine.indexOf('{');
  if (braceIdx > 20) {
    firstLine = firstLine.substring(0, braceIdx).trim();
    if (firstLine.endsWith('of') || firstLine.endsWith('-')) {
      firstLine = firstLine.substring(0, firstLine.length - 2).trim();
    }
  }
  if (firstLine.length > maxLen) {
    return '${firstLine.substring(0, maxLen)}…';
  }
  return firstLine;
}

String _availableRoutesHint({
  required AppLocalizations l10n,
  required int readyCloudNodeCount,
  required int savedProfileCount,
}) {
  return '$readyCloudNodeCount ${l10n.cloudNodes} · $savedProfileCount ${l10n.manualProfiles}';
}

String _connectionHeaderHint({
  required AppLocalizations l10n,
  required VpnProvider vpnProvider,
  required CloudProvider cloudProvider,
  required Profile? selectedProfile,
  required int savedProfileCount,
  required int readyCloudNodeCount,
}) {
  if (selectedProfile != null) {
    if (isCloudManagedProfile(selectedProfile)) {
      final providerLabel = _selectedCloudProviderLabel(
        cloudProvider: cloudProvider,
        selectedProfile: selectedProfile,
      );
      if (providerLabel != null) {
        return '$providerLabel · ${_statusLabel(vpnProvider.status, l10n, degraded: vpnProvider.isDegraded)}';
      }
      if (isUsableSavedCloudProfile(selectedProfile)) {
        return '${l10n.cloudNodes} · ${_statusLabel(vpnProvider.status, l10n, degraded: vpnProvider.isDegraded)}';
      }
    }
    return _statusLabel(vpnProvider.status, l10n,
        degraded: vpnProvider.isDegraded);
  }

  final routeSummary = _availableRoutesHint(
    l10n: l10n,
    readyCloudNodeCount: readyCloudNodeCount,
    savedProfileCount: savedProfileCount,
  );
  if (readyCloudNodeCount > 0 || savedProfileCount > 0) {
    return routeSummary;
  }
  if (cloudProvider.allInstances.isNotEmpty) {
    return l10n.waitingForCredentials;
  }
  if (!cloudProvider.hasApiKey && savedProfileCount == 0) {
    return cloudProvider.providerId == CloudProviderId.ssh
        ? l10n.setSshAccessHint
        : l10n.setCloudProviderApiKeyHint;
  }
  return l10n.noNodeSelectedHint;
}

String? _selectedCloudProviderLabel({
  required CloudProvider cloudProvider,
  required Profile selectedProfile,
}) {
  final instanceLabel = selectedProfile.name.replaceFirst(
    ProfileProvider.cloudManagedProfilePrefix,
    '',
  );
  final instance = cloudProvider.allInstances
      .where((candidate) => candidate.label == instanceLabel)
      .firstOrNull;
  final providerId = CloudProviderId.tryParse(instance?.provider);
  return providerId?.displayName;
}

String _egressValue(VpnProvider vpnProvider, AppLocalizations l10n) {
  if (!vpnProvider.isConnected) {
    return l10n.connectVpnToMeasure;
  }
  final currentIp = vpnProvider.diagnosticsEgressIp;
  if (currentIp != null) {
    return currentIp;
  }
  // Current probe did not land a fresh IP. If we ever confirmed one during
  // this session, show it with a "last seen" tag so the user sees a concrete
  // value rather than a misleading "unavailable" — the tunnel is still up
  // and routing traffic; only the probe lagged.
  final lastSeen = vpnProvider.lastKnownEgressIp;
  if (lastSeen != null) {
    return l10n.egressLastSeen(lastSeen);
  }
  if (vpnProvider.isRefreshingDiagnostics) {
    return l10n.refreshing;
  }
  return l10n.egressProbeBusy;
}

String? _egressHint(
  VpnProvider vpnProvider,
  CloudProvider cloudProvider,
  AppLocalizations l10n,
) {
  if (!vpnProvider.isConnected) {
    return null;
  }
  final currentIp = vpnProvider.diagnosticsEgressIp;
  if (currentIp != null) {
    // Reverse-lookup the egress IP against known cloud nodes. If it matches
    // a node OTHER than the user's currently-selected profile, sing-box's
    // urltest pool has silently routed through a failover member. Surface
    // that mismatch — otherwise the header still says "Cloud: vultr" while
    // traffic exits through node-260510061907 and the user has no idea
    // which node they're actually going through. Empirically confirmed on
    // 2026-05-12 when stale vultr ports caused this exact mis-labeling.
    final actualNode = cloudProvider.findCloudInstanceByEgressIp(currentIp);
    final activeProfileIp =
        cloudProvider.resolveEgressIpForProfileName(vpnProvider.activeProfile);
    if (actualNode != null &&
        activeProfileIp != null &&
        activeProfileIp != currentIp) {
      return l10n.egressViaFailover(actualNode.label);
    }
    return null;
  }
  // Probe failed or is pending but VPN is up — explicitly reassure the user
  // that traffic is still going through the tunnel, so a transient probe
  // failure doesn't look like a broken VPN.
  if (vpnProvider.lastKnownEgressIp != null) {
    return l10n.egressProbeStillRoutingHint;
  }
  if (vpnProvider.isRefreshingDiagnostics) {
    return l10n.egressProbeHelp;
  }
  final raw = vpnProvider.diagnosticsError;
  if (raw == null) {
    return l10n.egressProbeStillRoutingHint;
  }
  return localizeVpnStatusMessage(raw, l10n);
}

Color _statusColor(VpnStatus status, {bool degraded = false}) {
  switch (status) {
    case VpnStatus.connected:
      // Degraded == "tunnel is up but native checkTunnelHealth couldn't
      // verify the upstream". Render in orange so the user notices, instead
      // of the usual green that implies traffic is flowing.
      return degraded ? Colors.orange : Colors.green;
    case VpnStatus.connecting:
    case VpnStatus.disconnecting:
      return Colors.orange;
    case VpnStatus.disconnected:
      return Colors.grey;
  }
}

IconData _statusIcon(VpnStatus status, {bool degraded = false}) {
  switch (status) {
    case VpnStatus.connected:
      return degraded ? Icons.warning_amber_rounded : Icons.check_circle;
    case VpnStatus.connecting:
    case VpnStatus.disconnecting:
      return Icons.sync;
    case VpnStatus.disconnected:
      return Icons.cancel;
  }
}

String _statusLabel(
  VpnStatus status,
  AppLocalizations l10n, {
  bool degraded = false,
}) {
  switch (status) {
    case VpnStatus.connected:
      return degraded ? l10n.connectedDegraded : l10n.connected;
    case VpnStatus.connecting:
      return l10n.connecting;
    case VpnStatus.disconnecting:
      return l10n.disconnecting;
    case VpnStatus.disconnected:
      return l10n.disconnected;
  }
}

class _ConnectionDetailsTile extends StatelessWidget {
  const _ConnectionDetailsTile({
    required this.vpnProvider,
    required this.latestDecision,
  });

  final VpnProvider vpnProvider;
  final VpnRouteDecision? latestDecision;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final stats = vpnProvider.stats;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 2.h),
          childrenPadding: EdgeInsets.fromLTRB(14.w, 0, 14.w, 14.h),
          title: Text(
            l10n.connectionDetails,
            style: TextStyle(
              fontSize: 13.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            l10n.speedStats(stats.downloadSpeedFormatted),
            style: TextStyle(
              fontSize: 11.sp,
              color: Colors.grey[700],
            ),
          ),
          children: [
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
            if (latestDecision != null) ...[
              SizedBox(height: 12.h),
              _LatestRouteCard(decision: latestDecision!),
            ],
          ],
        ),
      ),
    );
  }
}

class _LatestRouteCard extends StatelessWidget {
  const _LatestRouteCard({required this.decision});

  final VpnRouteDecision decision;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = decision.isDirect ? Colors.teal : Colors.indigo;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34.w,
            height: 34.w,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(
              decision.isDirect
                  ? Icons.subdirectory_arrow_left
                  : Icons.cloud_outlined,
              size: 18.sp,
              color: color,
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.latestRoute,
                  style: TextStyle(
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[700],
                  ),
                ),
                SizedBox(height: 4.h),
                Text(
                  decision.displayTarget,
                  style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[900],
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  decision.isDirect
                      ? l10n.directRoute
                      : l10n.proxyRoute(decision.outboundTag),
                  style: TextStyle(
                    fontSize: 11.sp,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999.r),
            ),
            child: Text(
              decision.typeLabel,
              style: TextStyle(
                fontSize: 10.sp,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
