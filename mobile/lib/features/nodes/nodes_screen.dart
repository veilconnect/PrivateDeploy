import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../shared/utils/logger.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/cloud_provider_id.dart';
import '../cloud/node_detail_screen.dart';
import 'nodes_action_feedback.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_profile_actions.dart';
import 'nodes_sections.dart';
import 'nodes_screen_fab.dart';
import 'nodes_vpn_actions.dart';
import 'nodes_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../profiles/profile_content_screen.dart';
import '../profiles/profile_provider.dart';
import '../cdn/cdn_provider.dart';
import '../cdn/cdn_settings_screen.dart';
import '../profiles/profile_config_normalizer.dart';
import '../settings/app_settings_provider.dart';
import '../settings/settings_screen.dart';
import '../vpn/vpn_provider.dart';
import 'nodes_wireguard_card.dart';

/// Profile name used for the standalone WireGuard-only (intranet) tunnel — the
/// one brought up with no proxy node. Kept here so the connect call and the
/// proxy-state reconciliation in build() agree on the exact string.
const String kIntranetWireguardProfileName = 'Intranet WireGuard';

class NodesScreen extends StatefulWidget {
  const NodesScreen({Key? key}) : super(key: key);

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  bool _didBootstrap = false;
  final Map<String, ProfileSpeedResult> _profileSpeedResults = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapNodesState();
    });
  }

  Future<void> _bootstrapNodesState() async {
    if (!mounted || _didBootstrap) {
      return;
    }

    _didBootstrap = true;
    await _syncWorkspaceState(initializeVpn: true);
  }

  Future<void> _refreshAll() async {
    await _syncWorkspaceState(initializeVpn: false);
  }

  Future<void> _syncWorkspaceState({required bool initializeVpn}) async {
    final cloudProvider = context.read<CloudProvider>();
    final profileProvider = context.read<ProfileProvider>();
    final vpnProvider = context.read<VpnProvider>();

    // Run local-only operations first so the UI can render cached data fast.
    await Future.wait([
      profileProvider.loadProfiles(),
      if (initializeVpn) vpnProvider.initialize() else vpnProvider.loadStatus(),
    ]);

    if (!cloudProvider.hasApiKey) {
      // No saved access credentials — nothing to sync remotely.
      await cloudProvider.refreshCloudConfig();
      return;
    }

    // If we already have cached instances (restored from local storage in
    // CloudProvider._init), kick off the API sync in the background so the
    // user can connect immediately without waiting for a network round-trip.
    if (cloudProvider.allInstances.isNotEmpty) {
      unawaited(
          _backgroundCloudSync(cloudProvider, profileProvider, vpnProvider));
    } else {
      // No cached data — must wait for API so the user sees something.
      await cloudProvider.refreshCloudConfig();
      if (cloudProvider.hasApiKey) {
        await cloudProvider.loadInstances();
        unawaited(cloudProvider.loadRegions());
        unawaited(cloudProvider.loadPlans());
        await _reconcileCloudProfiles(
            cloudProvider, profileProvider, vpnProvider);
      }
    }
  }

  Future<void> _backgroundCloudSync(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) async {
    try {
      await cloudProvider.refreshCloudConfig();
      if (cloudProvider.hasApiKey) {
        await cloudProvider.loadInstances();
        unawaited(cloudProvider.loadRegions());
        unawaited(cloudProvider.loadPlans());
        await _reconcileCloudProfiles(
            cloudProvider, profileProvider, vpnProvider);
      }
    } catch (e) {
      // Background sync failure is non-critical — cached nodes remain usable.
      AppLogger.warning('[NodesScreen] Background cloud sync failed: $e');
    }
  }

  Future<void> _reconcileCloudProfiles(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) async {
    if (!cloudProvider.hasApiKey || cloudProvider.error != null) {
      return;
    }

    final existingCloudProfiles =
        cloudProvider.allInstances.map(cloudProfileName).toSet();
    final staleActiveProfile = profileProvider.activeProfile;
    final shouldDisconnect = staleActiveProfile != null &&
        isCloudManagedProfile(staleActiveProfile) &&
        !existingCloudProfiles.contains(staleActiveProfile.name) &&
        vpnProvider.status != VpnStatus.disconnected;

    if (shouldDisconnect) {
      await vpnProvider.disconnect();
    }

    await profileProvider.pruneMissingCloudProfiles(existingCloudProfiles);
  }

  Future<void> _refreshAfterCloudApiKeySaved() async {
    if (!mounted) {
      return;
    }

    await _syncWorkspaceState(initializeVpn: false);
  }

  Future<void> _showCloudApiKeyDialog(CloudProvider cloudProvider) {
    return showCloudApiKeyFlow(
      context: context,
      cloudProvider: cloudProvider,
      onSaved: _refreshAfterCloudApiKeySaved,
    );
  }

  Future<void> _showCreateCloudNodeDialog(CloudProvider cloudProvider) {
    return showCreateCloudNodeFlow(
      context: context,
      cloudProvider: cloudProvider,
    );
  }

  Future<void> _useCloudNode(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    CloudInstance instance,
  ) {
    _proxyActive = true;
    return useCloudNodeAndConnect(
      context: context,
      instance: instance,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    );
  }

  Future<void> _handleConnect(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) {
    return handleNodesConnect(
      context: context,
      vpnProvider: vpnProvider,
      profileProvider: profileProvider,
      cloudProvider: cloudProvider,
      onUseCloudNode: (instance) => _useCloudNode(
        cloudProvider,
        profileProvider,
        vpnProvider,
        instance,
      ),
    );
  }

  Future<void> _handleRestart(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) {
    return handleNodesRestart(
      context: context,
      vpnProvider: vpnProvider,
      profileProvider: profileProvider,
      cloudProvider: cloudProvider,
      onUseCloudNode: (instance) => _useCloudNode(
        cloudProvider,
        profileProvider,
        vpnProvider,
        instance,
      ),
    );
  }

  bool _wgBusy = false;

  /// Serializes the VPN mode transitions triggered from this screen (proxy
  /// connect/disconnect/restart, WG toggle, cloud-node "use"). The guard is
  /// engaged synchronously — BEFORE the action's first await — so a second
  /// tap can never slip through the event-loop yield and interleave two
  /// transitions. Re-entrant calls (an exclusive action invoking another
  /// handler internally) must call the unguarded handler directly.
  Future<void> _runBusyExclusive(Future<void> Function() action) async {
    if (_wgBusy) return; // a mode transition is already in flight
    setState(() => _wgBusy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _wgBusy = false);
    }
  }

  /// Whether the proxy (网络访问) node is the active connection. Tracked separately
  /// from the raw tunnel state so the intranet WireGuard overlay can run on its
  /// own (proxy disconnected, tunnel carrying only WireGuard) and vice versa.
  bool _proxyActive = false;

  /// Brings up a tunnel that carries ONLY the intranet WireGuard (LAN -> WG,
  /// everything else direct). Used when WireGuard should run without the proxy.
  Future<void> _connectWireguardOnly(VpnProvider vpnProvider) async {
    final appSettings = context.read<AppSettingsProvider>();
    final config =
        buildWireguardIntranetOnlyConfig(appSettings.wireGuardIntranet);
    if (config == null) {
      // Not configured, or the configured addresses don't yield a routable
      // CIDR — say so instead of silently doing nothing (or worse, starting
      // a tunnel with no WireGuard in it).
      if (mounted) {
        showNodesActionSnackBar(
          context,
          message: 'WireGuard 配置无效,请检查本地地址/网段 / '
              'Invalid WireGuard config — check local address/CIDRs',
          backgroundColor: Colors.orange,
        );
      }
      return;
    }
    if (vpnProvider.isConnected) {
      await vpnProvider.disconnect();
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await vpnProvider.connect(
      configJson: config,
      profileName: kIntranetWireguardProfileName,
      // No proxy upstream: tells VpnProvider to skip the proxy-oriented health
      // watchdog so it doesn't restart this tunnel every ~30-60s.
      proxyless: true,
    );
  }

  /// Main connect button: the user wants the proxy node in the tunnel.
  Future<void> _handleProxyConnect(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) {
    return _runBusyExclusive(() async {
      _proxyActive = true;
      await _handleConnect(cloudProvider, profileProvider, vpnProvider);
    });
  }

  /// Main disconnect button: drop the proxy from the tunnel. If the intranet
  /// WireGuard is still on, keep the tunnel up carrying only WireGuard;
  /// otherwise stop the tunnel entirely.
  Future<void> _handleProxyDisconnect(VpnProvider vpnProvider) {
    return _runBusyExclusive(() async {
      _proxyActive = false;
      final appSettings = context.read<AppSettingsProvider>();
      if (appSettings.wireGuardIntranet.isActive) {
        await _connectWireguardOnly(vpnProvider);
      } else {
        await handleNodesDisconnect(context: context, vpnProvider: vpnProvider);
      }
    });
  }

  /// Home-screen intranet WireGuard switch. Controls ONLY whether WireGuard is
  /// in the tunnel — independent of the proxy node. Applies live.
  Future<void> _handleWireguardToggle(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    bool enabled,
  ) {
    return _runBusyExclusive(() async {
      final appSettings = context.read<AppSettingsProvider>();
      await appSettings.setWireGuardIntranetEnabled(enabled);
      if (!mounted) {
        return;
      }
      if (enabled) {
        if (_proxyActive) {
          // Proxy wanted — (re)build proxy + WireGuard.
          if (vpnProvider.isConnected) {
            await _handleRestart(cloudProvider, profileProvider, vpnProvider);
          } else {
            await _handleConnect(cloudProvider, profileProvider, vpnProvider);
          }
        } else {
          // No proxy — run WireGuard on its own.
          await _connectWireguardOnly(vpnProvider);
        }
      } else if (vpnProvider.isConnected) {
        if (_proxyActive) {
          // Keep the proxy, drop WireGuard.
          await _handleRestart(cloudProvider, profileProvider, vpnProvider);
        } else {
          // Was WireGuard-only — turning it off stops the tunnel.
          await handleNodesDisconnect(
              context: context, vpnProvider: vpnProvider);
        }
      }
    });
  }

  Future<void> _openCloudNodeDetails(CloudInstance instance) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NodeDetailScreen(node: instance),
      ),
    );
  }

  Future<void> _deleteCloudNode(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    CloudInstance instance,
  ) {
    return confirmDeleteCloudNode(
      context: context,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
      instance: instance,
    );
  }

  Future<void> _repairCloudNode(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    CloudInstance instance,
  ) {
    return confirmRepairCloudNode(
      context: context,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
      instance: instance,
    );
  }

  Future<void> _testCloudNodeLatency(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    CloudInstance instance,
  ) {
    return testCloudNodeLatency(
      context: context,
      cloudProvider: cloudProvider,
      instance: instance,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    );
  }

  Future<void> _testAllCloudNodesLatency(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
  ) {
    return testAllCloudNodesLatency(
      context: context,
      cloudProvider: cloudProvider,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    );
  }

  Future<void> _activateProfile(
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    Profile profile,
  ) {
    _proxyActive = true;
    return activateProfileAndConnect(
      context: context,
      profile: profile,
      profileProvider: profileProvider,
      cloudProvider: cloudProvider,
      vpnProvider: vpnProvider,
    );
  }

  Future<void> _renameProfile(
    ProfileProvider profileProvider,
    Profile profile,
  ) {
    return showRenameProfileFlow(
      context: context,
      profile: profile,
      profileProvider: profileProvider,
    );
  }

  Future<void> _deleteProfile(
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    Profile profile,
  ) {
    return confirmDeleteProfile(
      context: context,
      profileProvider: profileProvider,
      profile: profile,
      vpnProvider: vpnProvider,
    );
  }

  Future<void> _testProfileSpeed(
    ProfileProvider profileProvider,
    VpnProvider vpnProvider,
    Profile profile,
  ) async {
    setState(() {
      _profileSpeedResults[profile.id] = const ProfileSpeedResult.testing();
    });

    final result = await testProfileSpeed(
      context: context,
      profile: profile,
      profileProvider: profileProvider,
      vpnProvider: vpnProvider,
    );

    if (mounted) {
      setState(() {
        _profileSpeedResults[profile.id] = result;
      });
    }
  }

  Future<void> _showImportProfileDialog() {
    return showImportProfileFlow(
      context: context,
      profileProvider: context.read<ProfileProvider>(),
    );
  }

  Future<void> _showCreateProfileDialog() {
    return showCreateProfileFlow(
      context: context,
      profileProvider: context.read<ProfileProvider>(),
    );
  }

  Future<void> _showWireguardDialog() {
    return showCreateWireguardFlow(
      context: context,
      profileProvider: context.read<ProfileProvider>(),
    );
  }

  void _openSettings() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => const SettingsScreen(),
      ),
    );
  }

  void _openCdnSettings() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => const CdnSettingsScreen(),
      ),
    );
  }

  /// Returns true when a CDN Worker is already deployed for whichever
  /// cloud node the active profile points at. Used to switch the
  /// guidance banner between "you need to set up CDN" and "CDN is on
  /// but still failing here" copy — the user already deployed once, so
  /// telling them to "set up CDN acceleration" again is misleading and
  /// actionless. Returns false when the active profile is local-only,
  /// the matching instance can't be found, or no deployment exists.
  bool _cdnDeployedForActiveProfile({
    required VpnProvider vpnProvider,
    required CloudProvider cloudProvider,
  }) {
    final profileName = vpnProvider.activeProfile;
    if (profileName == null ||
        !ProfileProvider.isCloudManagedProfileName(profileName)) {
      return false;
    }
    final label = profileName
        .substring(ProfileProvider.cloudManagedProfilePrefix.length)
        .trim();
    if (label.isEmpty) return false;
    CloudInstance? instance;
    for (final candidate in cloudProvider.allInstances) {
      if (candidate.label == label) {
        instance = candidate;
        break;
      }
    }
    if (instance == null) return false;
    final cdn = context.read<CdnProvider?>();
    if (cdn == null) return false;
    return cdn.deploymentFor(instance.id) != null;
  }

  Future<void> _switchManagedCloudProvider(
    CloudProvider cloudProvider,
    CloudProviderId providerId,
  ) async {
    if (cloudProvider.providerId == providerId) {
      return;
    }
    await cloudProvider.setActiveProvider(providerId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final listBottomPadding = 132.h + MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.connection),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: l10n.settings,
          ),
        ],
      ),
      body: Consumer3<CloudProvider, ProfileProvider, VpnProvider>(
        builder: (context, cloudProvider, profileProvider, vpnProvider, _) {
          // Reconcile the in-memory proxy-active flag with the real tunnel.
          // After an app process restart the flag defaults to false even if a
          // proxy tunnel is still up; without this, toggling WG would wrongly
          // tear the proxy down (or vice-versa). Use the authoritative
          // proxyless flag (restored from persisted session state) plus the
          // known WG-only profile name so a restored WG-only tunnel is never
          // mistaken for a proxy.
          if (!vpnProvider.isConnected) {
            _proxyActive = false;
          } else {
            _proxyActive = !vpnProvider.isProxylessTunnel &&
                vpnProvider.activeProfile != kIntranetWireguardProfileName;
          }
          final localProfiles = profileProvider.profiles
              .where((profile) => !isCloudManagedProfile(profile))
              .toList();
          final showLocalProfilesFirst = localProfiles.isNotEmpty &&
              connectableCloudInstances(cloudProvider).isEmpty;

          if (profileProvider.isLoading &&
              profileProvider.profiles.isEmpty &&
              cloudProvider.isLoading &&
              cloudProvider.allInstances.isEmpty) {
            return LoadingIndicator(message: l10n.loadingNodes);
          }

          return RefreshIndicator(
            onRefresh: _refreshAll,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                16.w,
                16.w,
                16.w,
                listBottomPadding,
              ),
              children: [
                if (vpnProvider.needsCdnGuidance)
                  _CdnGuidanceBanner(
                    // The banner has two distinct meanings depending on
                    // whether CDN is already deployed for the active
                    // cloud-managed node. Without this split the user
                    // who has *already* set up CDN sees "请设置 CDN 加速"
                    // when the real story is "CDN is on, but this
                    // location's network still can't route through it
                    // — try a different node" — confusing and actionless.
                    deploymentExists: _cdnDeployedForActiveProfile(
                      vpnProvider: vpnProvider,
                      cloudProvider: cloudProvider,
                    ),
                    onConfigure: _openCdnSettings,
                    onDismiss: vpnProvider.dismissCdnGuidance,
                  ),
                NodesVpnSection(
                  vpnProvider: vpnProvider,
                  profileProvider: profileProvider,
                  cloudProvider: cloudProvider,
                  showSetupShortcuts: false,
                  proxyConnected: _proxyActive,
                  busy: _wgBusy,
                  onConnect: () => _handleProxyConnect(
                      cloudProvider, profileProvider, vpnProvider),
                  onDisconnect: () => _handleProxyDisconnect(vpnProvider),
                  onRestart: () => _runBusyExclusive(() =>
                      _handleRestart(cloudProvider, profileProvider, vpnProvider)),
                  onConfigureApiKey: () =>
                      _showCloudApiKeyDialog(cloudProvider),
                  onImportProfile: _showImportProfileDialog,
                  onCreateCloudNode: () =>
                      _showCreateCloudNodeDialog(cloudProvider),
                  onRefreshRoutes: _refreshAll,
                ),
                SizedBox(height: 12.h),
                NodesWireguardCard(
                  busy: _wgBusy,
                  onSetEnabled: (enabled) => _handleWireguardToggle(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    enabled,
                  ),
                ),
                SizedBox(height: 20.h),
                if (showLocalProfilesFirst && localProfiles.isNotEmpty) ...[
                  NodesManualProfilesSection(
                    profiles: localProfiles,
                    activeProfileId: profileProvider.activeProfile?.id,
                    isConnected: vpnProvider.status == VpnStatus.connected,
                    speedResults: _profileSpeedResults,
                    onActivate: (profile) => _activateProfile(
                      cloudProvider,
                      profileProvider,
                      vpnProvider,
                      profile,
                    ),
                    onSpeedTest: (profile) => _testProfileSpeed(
                      profileProvider,
                      vpnProvider,
                      profile,
                    ),
                    onView: (profile) => _viewProfileContent(context, profile),
                    onEdit: (profile) =>
                        _renameProfile(profileProvider, profile),
                    onDelete: (profile) =>
                        _deleteProfile(profileProvider, vpnProvider, profile),
                  ),
                  SizedBox(height: 20.h),
                ],
                NodesCloudSection(
                  cloudProvider: cloudProvider,
                  profileProvider: profileProvider,
                  vpnProvider: vpnProvider,
                  suppressSetupActions: true,
                  onConfigureApiKey: () =>
                      _showCloudApiKeyDialog(cloudProvider),
                  onImportProfile: _showImportProfileDialog,
                  onRetryLoad: () => _refreshAll(),
                  onCreateCloudNode: () =>
                      _showCreateCloudNodeDialog(cloudProvider),
                  onViewDetails: _openCloudNodeDetails,
                  onRepairCloudNode: (instance) => _repairCloudNode(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    instance,
                  ),
                  onDeleteCloudNode: (instance) => _deleteCloudNode(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    instance,
                  ),
                  // Exclusive: a cloud-node connect is a multi-second mode
                  // transition; without the guard the WG toggle stays live
                  // during it and can fire a concurrent WG-only connect
                  // against the in-flight proxy start.
                  onUseCloudNode: (instance) => _runBusyExclusive(
                    () => _useCloudNode(
                      cloudProvider,
                      profileProvider,
                      vpnProvider,
                      instance,
                    ),
                  ),
                  onTestCloudNodeLatency: (instance) => _testCloudNodeLatency(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    instance,
                  ),
                  onTestAllCloudNodesLatency: () => _testAllCloudNodesLatency(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                  ),
                  onManageProviderChanged: (providerId) =>
                      _switchManagedCloudProvider(cloudProvider, providerId),
                ),
                if (!showLocalProfilesFirst && localProfiles.isNotEmpty) ...[
                  SizedBox(height: 20.h),
                  NodesManualProfilesSection(
                    profiles: localProfiles,
                    activeProfileId: profileProvider.activeProfile?.id,
                    isConnected: vpnProvider.status == VpnStatus.connected,
                    speedResults: _profileSpeedResults,
                    onActivate: (profile) => _activateProfile(
                      cloudProvider,
                      profileProvider,
                      vpnProvider,
                      profile,
                    ),
                    onSpeedTest: (profile) => _testProfileSpeed(
                      profileProvider,
                      vpnProvider,
                      profile,
                    ),
                    onView: (profile) => _viewProfileContent(context, profile),
                    onEdit: (profile) =>
                        _renameProfile(profileProvider, profile),
                    onDelete: (profile) =>
                        _deleteProfile(profileProvider, vpnProvider, profile),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: Consumer<CloudProvider>(
        builder: (context, cloudProvider, child) {
          return NodesScreenFab(
            cloudAccessActionLabel:
                cloudProvider.providerId == CloudProviderId.ssh
                    ? l10n.setSshAccess
                    : l10n.setCloudAccess,
            onConfigureCloudAccess: () => _showCloudApiKeyDialog(cloudProvider),
            onCreateCloudNode: cloudProvider.hasStoredApiKey
                ? () => _showCreateCloudNodeDialog(cloudProvider)
                : null,
            onImportProfile: _showImportProfileDialog,
            onCreateProfile: _showCreateProfileDialog,
            onAddWireguard: _showWireguardDialog,
          );
        },
      ),
    );
  }

  void _viewProfileContent(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final content = await provider.getProfileContent(profile.id);

    if (!context.mounted) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileContentScreen(
          profile: profile,
          content: content ?? '',
        ),
      ),
    );
  }
}

/// Surfaced at the top of the nodes screen when [VpnProvider.needsCdnGuidance]
/// is set — i.e. the native side reported that every start attempt failed
/// while cellular was the active underlying transport. That's the
/// China-Mobile-RST-to-Vultr-IP scenario the CDN-acceleration feature
/// targets; we point the user at the settings entry rather than leaving
/// them with a generic "VPN failed to start" toast.
class _CdnGuidanceBanner extends StatelessWidget {
  const _CdnGuidanceBanner({
    required this.deploymentExists,
    required this.onConfigure,
    required this.onDismiss,
  });

  /// True when the active cloud-managed node already has a CDN Worker
  /// deployment in [CdnProvider]. Drives the entire copy + action set:
  /// the "please set up CDN" framing only makes sense when there's no
  /// existing deployment to point at.
  final bool deploymentExists;
  final VoidCallback onConfigure;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final title = deploymentExists
        ? l10n.cdnGuidanceTitleDeployed
        : l10n.cdnGuidanceTitle;
    final body =
        deploymentExists ? l10n.cdnGuidanceBodyDeployed : l10n.cdnGuidanceBody;
    final actionLabel = deploymentExists
        ? l10n.cdnGuidanceActionRedeploy
        : l10n.cdnGuidanceConfigure;
    return Container(
      margin: EdgeInsets.only(bottom: 12.h),
      padding: EdgeInsets.fromLTRB(16.w, 12.h, 12.w, 12.h),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.error, size: 22.sp),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onErrorContainer,
                    fontSize: 15.sp,
                  ),
                ),
                SizedBox(height: 4.h),
                Text(
                  body,
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 13.sp,
                    height: 1.35,
                  ),
                ),
                SizedBox(height: 6.h),
                // One-line plain-English summary of *how* CDN
                // acceleration works, so a user who's never read the
                // intro card on the CDN settings page can still
                // understand what the action button is about to do
                // — and decide whether to tap it. Without this, the
                // banner read like a vague "do this magic thing".
                _HowItWorksLink(scheme: scheme),
                SizedBox(height: 8.h),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: onConfigure,
                      icon: Icon(
                        deploymentExists
                            ? Icons.refresh_rounded
                            : Icons.cloud_outlined,
                        size: 18,
                      ),
                      label: Text(actionLabel),
                    ),
                    SizedBox(width: 8.w),
                    TextButton(
                      onPressed: onDismiss,
                      child: Text(l10n.cdnGuidanceDismiss),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline "how does CDN acceleration work?" line that expands into a
/// dialog on tap. Lives next to the guidance banner so a confused user
/// has a one-tap answer to "what's this thing about to do to my
/// Cloudflare account?" — without having to navigate into CDN settings
/// just to read the explanation.
class _HowItWorksLink extends StatelessWidget {
  const _HowItWorksLink({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      onTap: () => _showExplainer(context, scheme),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 14.sp,
              color: scheme.onErrorContainer.withValues(alpha: 0.75)),
          SizedBox(width: 4.w),
          Flexible(
            child: Text(
              l10n.cdnGuidanceHowItWorksLink,
              style: TextStyle(
                fontSize: 12.sp,
                color: scheme.onErrorContainer.withValues(alpha: 0.85),
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showExplainer(BuildContext context, ColorScheme scheme) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cdnGuidanceHowItWorksTitle),
        content: SingleChildScrollView(
          child: Text(
            l10n.cdnGuidanceHowItWorksBody,
            style: TextStyle(fontSize: 14.sp, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cdnGuidanceHowItWorksClose),
          ),
        ],
      ),
    );
  }
}
