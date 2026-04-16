import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../shared/utils/logger.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/node_detail_screen.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_profile_actions.dart';
import 'nodes_sections.dart';
import 'nodes_screen_fab.dart';
import 'nodes_test_keys.dart';
import 'nodes_vpn_actions.dart';
import 'nodes_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../profiles/profile_content_screen.dart';
import '../profiles/profile_provider.dart';
import '../settings/settings_screen.dart';
import '../vpn/vpn_provider.dart';

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
      // No API key — nothing to sync remotely.
      await cloudProvider.refreshCloudConfig();
      return;
    }

    // If we already have cached instances (restored from local storage in
    // CloudProvider._init), kick off the API sync in the background so the
    // user can connect immediately without waiting for a network round-trip.
    if (cloudProvider.allInstances.isNotEmpty) {
      unawaited(_backgroundCloudSync(
          cloudProvider, profileProvider, vpnProvider));
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
    Profile profile,
  ) {
    return confirmDeleteProfile(
      context: context,
      profileProvider: profileProvider,
      profile: profile,
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

  void _openSettings() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => const SettingsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.workspace),
        actions: [
          IconButton(
            icon: const Icon(Icons.key),
            onPressed: () =>
                _showCloudApiKeyDialog(context.read<CloudProvider>()),
            tooltip: l10n.cloudApiKey,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
            tooltip: l10n.refresh,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: l10n.settings,
          ),
        ],
      ),
      body: Consumer3<CloudProvider, ProfileProvider, VpnProvider>(
        builder: (context, cloudProvider, profileProvider, vpnProvider, _) {
          final localProfiles = profileProvider.profiles
              .where((profile) => !isCloudManagedProfile(profile))
              .toList();

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
              padding: EdgeInsets.all(16.w),
              children: [
                NodesVpnSection(
                  vpnProvider: vpnProvider,
                  profileProvider: profileProvider,
                  cloudProvider: cloudProvider,
                  onConnect: () => _handleConnect(
                      cloudProvider, profileProvider, vpnProvider),
                  onDisconnect: () => handleNodesDisconnect(
                    context: context,
                    vpnProvider: vpnProvider,
                  ),
                  onRestart: () => _handleRestart(
                      cloudProvider, profileProvider, vpnProvider),
                ),
                if (vpnProvider.error != null) ...[
                  SizedBox(height: 12.h),
                  KeyedSubtree(
                    key: NodesTestKeys.vpnNoticeCard,
                    child: NodesInlineInfoCard(
                      icon: Icons.error_outline,
                      title: l10n.vpnNotice,
                      message: vpnProvider.error!,
                    ),
                  ),
                ],
                SizedBox(height: 20.h),
                NodesCloudSection(
                  cloudProvider: cloudProvider,
                  profileProvider: profileProvider,
                  vpnProvider: vpnProvider,
                  onConfigureApiKey: () =>
                      _showCloudApiKeyDialog(cloudProvider),
                  onRetryLoad: () => _refreshAll(),
                  onCreateCloudNode: () =>
                      _showCreateCloudNodeDialog(cloudProvider),
                  onViewDetails: _openCloudNodeDetails,
                  onDeleteCloudNode: (instance) => _deleteCloudNode(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    instance,
                  ),
                  onUseCloudNode: (instance) => _useCloudNode(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                    instance,
                  ),
                  onTestCloudNodeLatency: (instance) => _testCloudNodeLatency(
                      cloudProvider, profileProvider, vpnProvider, instance),
                  onTestAllCloudNodesLatency: () => _testAllCloudNodesLatency(
                    cloudProvider,
                    profileProvider,
                    vpnProvider,
                  ),
                ),
                if (localProfiles.isNotEmpty) ...[
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
                        _deleteProfile(profileProvider, profile),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: Consumer<CloudProvider>(
        builder: (context, cloudProvider, _) {
          return NodesScreenFab(
            showDeployNode: cloudProvider.hasApiKey,
            onDeployNode: () => _showCreateCloudNodeDialog(cloudProvider),
            onImportProfile: _showImportProfileDialog,
            onCreateProfile: _showCreateProfileDialog,
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
