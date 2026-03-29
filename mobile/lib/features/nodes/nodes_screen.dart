import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_provider.dart';
import '../cloud/node_detail_screen.dart';
import 'nodes_cloud_actions.dart';
import 'nodes_profile_actions.dart';
import 'nodes_sections.dart';
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
  bool _bootstrapTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapNodesState();
    });
  }

  Future<void> _bootstrapNodesState() async {
    if (!mounted || _bootstrapTriggered) {
      return;
    }

    _bootstrapTriggered = true;
    final cloudProvider = context.read<CloudProvider>();
    final profileProvider = context.read<ProfileProvider>();
    final vpnProvider = context.read<VpnProvider>();

    await profileProvider.loadProfiles();
    await vpnProvider.initialize();
    await cloudProvider.refreshCloudConfig();
    if (cloudProvider.hasApiKey) {
      await cloudProvider.loadInstances();
      await _reconcileCloudProfiles(
          cloudProvider, profileProvider, vpnProvider);
    }
  }

  Future<void> _refreshAll(BuildContext context) async {
    final cloudProvider = context.read<CloudProvider>();
    final profileProvider = context.read<ProfileProvider>();
    final vpnProvider = context.read<VpnProvider>();

    await profileProvider.loadProfiles();
    await vpnProvider.loadStatus();
    await cloudProvider.refreshCloudConfig();
    if (cloudProvider.hasApiKey) {
      await cloudProvider.loadInstances();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspace'),
        actions: [
          IconButton(
            icon: const Icon(Icons.key),
            onPressed: () => showCloudApiKeyFlow(
              context: context,
              cloudProvider: context.read<CloudProvider>(),
              onSaved: () async {
                _bootstrapTriggered = false;
                await _refreshAll(context);
              },
            ),
            tooltip: 'Cloud API Key',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _refreshAll(context),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Consumer3<CloudProvider, ProfileProvider, VpnProvider>(
        builder: (context, cloudProvider, profileProvider, vpnProvider, _) {
          if (!_bootstrapTriggered) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _bootstrapNodesState();
            });
          }

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
            onRefresh: () => _refreshAll(context),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(16.w),
              children: [
                NodesVpnSection(
                  vpnProvider: vpnProvider,
                  profileProvider: profileProvider,
                  cloudProvider: cloudProvider,
                  onConnect: () => handleNodesConnect(
                    context: context,
                    vpnProvider: vpnProvider,
                    profileProvider: profileProvider,
                    cloudProvider: cloudProvider,
                    onUseCloudNode: (instance) => useCloudNodeAndConnect(
                      context: context,
                      instance: instance,
                      cloudProvider: cloudProvider,
                      profileProvider: profileProvider,
                      vpnProvider: vpnProvider,
                    ),
                  ),
                  onDisconnect: () => handleNodesDisconnect(
                    context: context,
                    vpnProvider: vpnProvider,
                  ),
                  onRestart: () => handleNodesRestart(
                    context: context,
                    vpnProvider: vpnProvider,
                    profileProvider: profileProvider,
                    cloudProvider: cloudProvider,
                    onUseCloudNode: (instance) => useCloudNodeAndConnect(
                      context: context,
                      instance: instance,
                      cloudProvider: cloudProvider,
                      profileProvider: profileProvider,
                      vpnProvider: vpnProvider,
                    ),
                  ),
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
                  onConfigureApiKey: () => showCloudApiKeyFlow(
                    context: context,
                    cloudProvider: cloudProvider,
                    onSaved: () async {
                      _bootstrapTriggered = false;
                      await _refreshAll(context);
                    },
                  ),
                  onRetryLoad: cloudProvider.loadInstances,
                  onCreateCloudNode: () => showCreateCloudNodeFlow(
                    context: context,
                    cloudProvider: cloudProvider,
                  ),
                  onViewDetails: (instance) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NodeDetailScreen(node: instance),
                      ),
                    );
                  },
                  onDeleteCloudNode: (instance) => confirmDeleteCloudNode(
                    context: context,
                    cloudProvider: cloudProvider,
                    profileProvider: profileProvider,
                    vpnProvider: vpnProvider,
                    instance: instance,
                  ),
                  onUseCloudNode: (instance) => useCloudNodeAndConnect(
                    context: context,
                    instance: instance,
                    cloudProvider: cloudProvider,
                    profileProvider: profileProvider,
                    vpnProvider: vpnProvider,
                  ),
                ),
                if (localProfiles.isNotEmpty) ...[
                  SizedBox(height: 20.h),
                  NodesManualProfilesSection(
                    profiles: localProfiles,
                    activeProfileId: profileProvider.activeProfile?.id,
                    onActivate: (profile) => activateProfileAndConnect(
                      context: context,
                      profile: profile,
                      profileProvider: profileProvider,
                      cloudProvider: cloudProvider,
                      vpnProvider: vpnProvider,
                    ),
                    onView: (profile) => _viewProfileContent(context, profile),
                    onEdit: (profile) => showRenameProfileFlow(
                      context: context,
                      profile: profile,
                      profileProvider: profileProvider,
                    ),
                    onDelete: (profile) => confirmDeleteProfile(
                      context: context,
                      profileProvider: profileProvider,
                      profile: profile,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: Consumer<CloudProvider>(
        builder: (context, cloudProvider, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cloudProvider.hasApiKey)
                FloatingActionButton.small(
                  heroTag: 'deploy_node',
                  onPressed: () => showCreateCloudNodeFlow(
                    context: context,
                    cloudProvider: cloudProvider,
                  ),
                  child: const Icon(Icons.cloud_upload),
                ),
              if (cloudProvider.hasApiKey) SizedBox(height: 8.h),
              FloatingActionButton.small(
                heroTag: 'import_profile',
                onPressed: () => showImportProfileFlow(
                  context: context,
                  profileProvider: context.read<ProfileProvider>(),
                ),
                child: const Icon(Icons.link),
              ),
              SizedBox(height: 8.h),
              FloatingActionButton(
                heroTag: 'create_profile',
                onPressed: () => showCreateProfileFlow(
                  context: context,
                  profileProvider: context.read<ProfileProvider>(),
                ),
                child: const Icon(Icons.add),
              ),
            ],
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
