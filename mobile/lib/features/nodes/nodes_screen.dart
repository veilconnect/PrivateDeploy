import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/node_detail_screen.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_profile_actions.dart';
import 'nodes_sections.dart';
import 'nodes_screen_fab.dart';
import 'nodes_vpn_actions.dart';
import 'nodes_widgets.dart';
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

    // Run independent local operations in parallel to cut startup latency.
    await Future.wait([
      profileProvider.loadProfiles(),
      if (initializeVpn)
        vpnProvider.initialize()
      else
        vpnProvider.loadStatus(),
      cloudProvider.refreshCloudConfig(),
    ]);

    if (cloudProvider.hasApiKey) {
      await cloudProvider.loadInstances();
      unawaited(cloudProvider.loadRegions());
      unawaited(cloudProvider.loadPlans());
      await _reconcileCloudProfiles(
          cloudProvider, profileProvider, vpnProvider);
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
        cloudProvider.instances.map(cloudProfileName).toSet();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspace'),
        actions: [
          IconButton(
            icon: const Icon(Icons.key),
            onPressed: () =>
                _showCloudApiKeyDialog(context.read<CloudProvider>()),
            tooltip: 'Cloud API Key',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: 'Settings',
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
              cloudProvider.instances.isEmpty) {
            return const LoadingIndicator(message: 'Loading nodes...');
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
                  NodesInlineInfoCard(
                    icon: Icons.error_outline,
                    title: 'VPN notice',
                    message: vpnProvider.error!,
                  ),
                ],
                SizedBox(height: 20.h),
                NodesCloudSection(
                  cloudProvider: cloudProvider,
                  profileProvider: profileProvider,
                  vpnProvider: vpnProvider,
                  onConfigureApiKey: () =>
                      _showCloudApiKeyDialog(cloudProvider),
                  onRetryLoad: cloudProvider.loadInstances,
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
                  onTestCloudNodeLatency: (instance) =>
                      _testCloudNodeLatency(cloudProvider, profileProvider, vpnProvider, instance),
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
                    onActivate: (profile) => _activateProfile(
                      cloudProvider,
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
