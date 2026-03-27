import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/subscription/parser.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../cloud/cloud_models.dart';
import '../cloud/node_detail_screen.dart';
import '../cloud/cloud_provider.dart';
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
        cloudProvider.instances.map(_cloudProfileName).toSet();
    final staleActiveProfile = profileProvider.activeProfile;
    final shouldDisconnect = staleActiveProfile != null &&
        _isCloudManagedProfile(staleActiveProfile) &&
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
            onPressed: () => _showApiKeyDialog(context),
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
              .where((profile) => !_isCloudManagedProfile(profile))
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
                _buildVpnSection(
                  context,
                  vpnProvider,
                  profileProvider,
                  cloudProvider,
                ),
                if (vpnProvider.error != null) ...[
                  SizedBox(height: 12.h),
                  _buildInlineInfoCard(
                    icon: Icons.error_outline,
                    title: 'VPN notice',
                    message: vpnProvider.error!,
                  ),
                ],
                SizedBox(height: 20.h),
                _buildCloudSection(
                  context,
                  cloudProvider,
                  profileProvider,
                ),
                SizedBox(height: 20.h),
                _buildSectionHeader(
                  title: 'Manual Profiles',
                  subtitle: 'Local configs and imported subscriptions',
                  count: localProfiles.length,
                ),
                SizedBox(height: 8.h),
                if (localProfiles.isEmpty)
                  _buildInlineInfoCard(
                    icon: Icons.description_outlined,
                    title: 'No manual profiles',
                    message:
                        'Create a local config or import a subscription URL.',
                    actionLabel: 'Create Profile',
                    onAction: () => _showCreateDialog(context),
                  )
                else
                  ...localProfiles.map(
                    (profile) => _buildProfileCard(
                      context,
                      profile,
                      profileProvider,
                    ),
                  ),
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
                  onPressed: () => _showCreateCloudDialog(context),
                  child: const Icon(Icons.cloud_upload),
                ),
              if (cloudProvider.hasApiKey) SizedBox(height: 8.h),
              FloatingActionButton.small(
                heroTag: 'import_profile',
                onPressed: () => _showImportDialog(context),
                child: const Icon(Icons.link),
              ),
              SizedBox(height: 8.h),
              FloatingActionButton(
                heroTag: 'create_profile',
                onPressed: () => _showCreateDialog(context),
                child: const Icon(Icons.add),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVpnSection(
    BuildContext context,
    VpnProvider vpnProvider,
    ProfileProvider profileProvider,
    CloudProvider cloudProvider,
  ) {
    final statusColor = _statusColor(vpnProvider.status);
    final selectedProfile = profileProvider.activeProfile?.name;
    final stats = vpnProvider.stats;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24.r,
                  backgroundColor: statusColor,
                  child: Icon(
                    _statusIcon(vpnProvider.status),
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connection',
                        style: TextStyle(
                          fontSize: 18.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        _statusLabel(vpnProvider.status),
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14.sp,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        selectedProfile != null
                            ? 'Selected node: $selectedProfile'
                            : _connectionHint(cloudProvider),
                        style:
                            TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (vpnProvider.isConnected) ...[
              SizedBox(height: 14.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  _buildChip('Up ${stats.uploadFormatted}', Colors.blue),
                  _buildChip('Down ${stats.downloadFormatted}', Colors.green),
                  _buildChip(
                    'Speed ${stats.downloadSpeedFormatted}',
                    Colors.purple,
                  ),
                ],
              ),
            ],
            SizedBox(height: 16.h),
            if (!vpnProvider.isSupported)
              _buildInlineInfoCard(
                icon: Icons.info_outline,
                title: 'Native VPN unavailable',
                message: vpnProvider.unsupportedReason ??
                    'This build does not include a usable native VPN runtime.',
              )
            else if (vpnProvider.isLoading)
              const LoadingIndicator(message: 'Processing VPN...')
            else
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: vpnProvider.status == VpnStatus.disconnected
                          ? () => _handleConnect(context, vpnProvider)
                          : vpnProvider.status == VpnStatus.connected
                              ? () => _handleDisconnect(context, vpnProvider)
                              : null,
                      icon: Icon(
                        vpnProvider.status == VpnStatus.connected
                            ? Icons.power_settings_new
                            : Icons.shield,
                      ),
                      label: Text(
                        vpnProvider.status == VpnStatus.connected
                            ? 'Disconnect'
                            : 'Connect',
                      ),
                    ),
                  ),
                  if (vpnProvider.status == VpnStatus.connected) ...[
                    SizedBox(height: 10.h),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _handleRestart(context, vpnProvider),
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Restart VPN'),
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

  Widget _buildCloudSection(
    BuildContext context,
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
  ) {
    if (!cloudProvider.hasApiKey) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            title: 'Cloud Nodes',
            subtitle: 'Deploy and use nodes from your cloud account',
            count: 0,
          ),
          SizedBox(height: 8.h),
          _buildInlineInfoCard(
            icon: Icons.cloud_off,
            title: 'Cloud access not configured',
            message:
                'Save your Vultr API key to deploy nodes directly from this device.',
            actionLabel: 'Set API Key',
            onAction: () => _showApiKeyDialog(context),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          title: 'Cloud Nodes',
          subtitle: 'Deploy, sync, and use cloud-backed nodes',
          count: cloudProvider.instances.length,
        ),
        SizedBox(height: 8.h),
        if (cloudProvider.error != null && cloudProvider.instances.isEmpty)
          _buildInlineInfoCard(
            icon: Icons.error_outline,
            title: 'Failed to load cloud nodes',
            message: cloudProvider.error!,
            actionLabel: 'Retry',
            onAction: () => cloudProvider.loadInstances(),
          )
        else if (cloudProvider.instances.isEmpty)
          _buildInlineInfoCard(
            icon: Icons.cloud_queue,
            title: 'No cloud nodes yet',
            message:
                'Deploy your first node here. Once it becomes active, use it directly from this page.',
            actionLabel: 'Deploy Node',
            onAction: () => _showCreateCloudDialog(context),
          )
        else
          ...cloudProvider.instances.map(
            (instance) => _buildCloudInstanceCard(
              context,
              instance,
              cloudProvider,
              profileProvider,
            ),
          ),
      ],
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String subtitle,
    required int count,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 2.h),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12.sp,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14.r),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: Colors.blue[700],
              fontSize: 12.sp,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInlineInfoCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28.sp, color: Colors.blueGrey),
            SizedBox(height: 12.h),
            Text(
              title,
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6.h),
            Text(
              message,
              style: TextStyle(fontSize: 13.sp, color: Colors.grey[700]),
            ),
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: 14.h),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCloudInstanceCard(
    BuildContext context,
    CloudInstance instance,
    CloudProvider cloudProvider,
    ProfileProvider profileProvider,
  ) {
    final isReady =
        instance.isActive && instance.hasIp && instance.nodeInfo != null;
    final profileName = _cloudProfileName(instance);
    final linkedProfile = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;
    final isSelected = profileProvider.activeProfile?.name == profileName;
    final vpnProvider = context.read<VpnProvider>();
    final isConnected = vpnProvider.status == VpnStatus.connected;
    final canUseNode = !isSelected || !isConnected;
    final primaryLabel = isSelected
        ? (isConnected ? 'Active Node' : 'Connect')
        : (isConnected ? 'Use & Switch' : 'Use & Connect');
    final primaryIcon = isSelected
        ? (isConnected ? Icons.check_circle : Icons.shield)
        : Icons.play_arrow;

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor:
                      instance.isActive ? Colors.green : Colors.orange,
                  child: Icon(
                    instance.isActive
                        ? Icons.cloud_done
                        : Icons.hourglass_empty,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instance.label,
                        style: TextStyle(
                          fontSize: 16.sp,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        'Status: ${instance.status} • Region: ${instance.region}',
                        style: TextStyle(fontSize: 12.sp),
                      ),
                      if (instance.hasIp)
                        Text(
                          'IP: ${instance.ipv4}',
                          style: TextStyle(fontSize: 12.sp),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'details') {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NodeDetailScreen(node: instance),
                        ),
                      );
                      return;
                    }
                    if (value == 'delete') {
                      _confirmDeleteCloudNode(context, instance);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'details',
                      child: Row(
                        children: [
                          Icon(Icons.info_outline),
                          SizedBox(width: 8),
                          Text('Node Details'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 8),
                          Text(
                            'Delete Node',
                            style: TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                _buildChip(instance.isActive ? 'ACTIVE' : 'PROVISIONING',
                    instance.isActive ? Colors.green : Colors.orange),
                if (instance.isActive &&
                    instance.hasIp &&
                    instance.nodeInfo == null)
                  _buildChip('LOCAL CREDS MISSING', Colors.deepOrange),
                if (linkedProfile != null)
                  _buildChip(
                    isSelected ? 'IN USE' : 'SYNCED',
                    isSelected ? Colors.blue : Colors.teal,
                  ),
                if (instance.nodeInfo != null)
                  _buildChip('SS / Hy2 / VLESS / Trojan', Colors.indigo),
              ],
            ),
            if (instance.isActive && instance.hasIp && instance.nodeInfo == null)
              Padding(
                padding: EdgeInsets.only(top: 10.h),
                child: Text(
                  'This server was found in your Vultr account, but this phone does not have its connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.',
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: Colors.grey[700],
                  ),
                ),
              ),
            if (isReady) ...[
              SizedBox(height: 14.h),
              FilledButton.icon(
                onPressed: canUseNode
                    ? () => _useCloudNode(context, instance, cloudProvider)
                    : null,
                icon: Icon(primaryIcon),
                label: Text(primaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    Profile profile,
    ProfileProvider provider,
  ) {
    final isActive = profile.id == provider.activeProfile?.id;

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isActive ? Colors.green : Colors.grey,
          child: Icon(
            isActive ? Icons.check : Icons.description,
            color: Colors.white,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                profile.name,
                style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (isActive) _buildChip('ACTIVE', Colors.green),
          ],
        ),
        subtitle: Padding(
          padding: EdgeInsets.only(top: 4.h),
          child: Text(
            'Created: ${_formatDate(profile.createdAt)}',
            style: TextStyle(fontSize: 12.sp, color: Colors.grey[600]),
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'activate':
                _activateProfile(context, profile);
                break;
              case 'view':
                _viewProfileContent(context, profile);
                break;
              case 'edit':
                _showEditDialog(context, profile);
                break;
              case 'delete':
                _confirmDeleteProfile(context, profile);
                break;
            }
          },
          itemBuilder: (context) => [
            if (!isActive)
              const PopupMenuItem(
                value: 'activate',
                child: Row(
                  children: [
                    Icon(Icons.play_arrow),
                    SizedBox(width: 8),
                    Text('Use & Connect'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'view',
              child: Row(
                children: [
                  Icon(Icons.visibility),
                  SizedBox(width: 8),
                  Text('View / Edit Config'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit),
                  SizedBox(width: 8),
                  Text('Rename'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(String text, MaterialColor color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color[700],
          fontSize: 10.sp,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Color _statusColor(VpnStatus status) {
    switch (status) {
      case VpnStatus.connected:
        return Colors.green;
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return Colors.orange;
      case VpnStatus.disconnected:
        return Colors.grey;
    }
  }

  IconData _statusIcon(VpnStatus status) {
    switch (status) {
      case VpnStatus.connected:
        return Icons.check_circle;
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return Icons.sync;
      case VpnStatus.disconnected:
        return Icons.cancel;
    }
  }

  String _statusLabel(VpnStatus status) {
    switch (status) {
      case VpnStatus.connected:
        return 'Connected';
      case VpnStatus.connecting:
        return 'Connecting...';
      case VpnStatus.disconnecting:
        return 'Disconnecting...';
      case VpnStatus.disconnected:
        return 'Disconnected';
    }
  }

  String _connectionHint(CloudProvider cloudProvider) {
    final readyCloudNodes = _connectableCloudInstances(cloudProvider);
    if (readyCloudNodes.length == 1) {
      return 'Tap Connect to use your ready cloud node automatically.';
    }
    if (readyCloudNodes.length > 1) {
      return 'Tap Connect to choose one of your ready cloud nodes, or select a local profile below.';
    }
    if (cloudProvider.instances.isNotEmpty) {
      return 'Cloud nodes are visible, but this device still needs their local credentials before it can connect.';
    }
    return 'Choose a node or local profile below before connecting.';
  }

  List<CloudInstance> _connectableCloudInstances(CloudProvider cloudProvider) {
    return cloudProvider.instances
        .where((instance) =>
            instance.isActive && instance.hasIp && instance.nodeInfo != null)
        .toList();
  }

  Future<CloudInstance?> _pickCloudNodeForConnect(
    BuildContext context,
    List<CloudInstance> candidates,
  ) {
    return showModalBottomSheet<CloudInstance>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose a cloud node',
                  style: TextStyle(
                    fontSize: 18.sp,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 6.h),
                Text(
                  'Connect needs one active node. Pick which cloud node to use now.',
                  style: TextStyle(
                    fontSize: 13.sp,
                    color: Colors.grey[700],
                  ),
                ),
                SizedBox(height: 12.h),
                ...candidates.map(
                  (instance) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_done, color: Colors.green),
                    title: Text(instance.label),
                    subtitle: Text(
                      '${instance.region}${instance.ipv4 != null ? ' • ${instance.ipv4}' : ''}',
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(instance),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _useCloudNode(
    BuildContext context,
    CloudInstance instance,
    CloudProvider cloudProvider,
  ) async {
    final config = cloudProvider.generateNodeConfig(instance);
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Node is not ready yet'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final profileProvider = context.read<ProfileProvider>();
    final profileName = _cloudProfileName(instance);
    final existing = profileProvider.profiles
        .where((profile) => profile.name == profileName)
        .firstOrNull;

    var success = true;
    if (existing == null) {
      success = await profileProvider.createProfile(
        name: profileName,
        content: config,
      );
      final created = profileProvider.profiles
          .where((profile) => profile.name == profileName)
          .firstOrNull;
      if (success && created != null) {
        success = await profileProvider.activateProfile(created.id);
      }
    } else {
      success = await profileProvider.saveProfileContent(existing.id, config);
      if (success) {
        success = await profileProvider.activateProfile(existing.id);
      }
    }

    if (!context.mounted) {
      return;
    }

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(profileProvider.error ?? 'Failed to activate node'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await _connectSelectedProfile(
      context,
      context.read<VpnProvider>(),
      profileProvider,
      successMessage: 'Node is ready and connected',
    );
  }

  Future<void> _activateProfile(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final success = await provider.activateProfile(profile.id);

    if (!context.mounted) {
      return;
    }

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.error ?? 'Failed to activate'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await _connectSelectedProfile(
      context,
      context.read<VpnProvider>(),
      provider,
      successMessage: 'Profile activated and connected',
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

  void _showEditDialog(BuildContext context, Profile profile) {
    final nameController = TextEditingController(text: profile.name);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Profile'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Profile Name'),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter a profile name';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) {
                return;
              }
              Navigator.pop(context);
              final provider = context.read<ProfileProvider>();
              final success = await provider.updateProfile(
                id: profile.id,
                name: nameController.text,
              );

              if (!context.mounted) {
                return;
              }

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    success
                        ? 'Profile renamed'
                        : provider.error ?? 'Failed to rename',
                  ),
                  backgroundColor: success ? Colors.green : Colors.red,
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteProfile(BuildContext context, Profile profile) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Profile'),
        content: Text('Are you sure you want to delete "${profile.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(context);
              final provider = context.read<ProfileProvider>();
              final success = await provider.deleteProfile(profile.id);

              if (!context.mounted) {
                return;
              }

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    success
                        ? 'Profile deleted'
                        : provider.error ?? 'Failed to delete',
                  ),
                  backgroundColor: success ? Colors.green : Colors.red,
                ),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context) {
    final urlController = TextEditingController();
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import from URL'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  hintText: 'e.g. My Subscription',
                ),
              ),
              SizedBox(height: 16.h),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL',
                  hintText: 'https://example.com/sub?token=...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = urlController.text.trim();
              final name = nameController.text.trim();
              if (url.isEmpty) {
                return;
              }

              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Fetching subscription...')),
              );

              try {
                final dio = Dio(
                  BaseOptions(
                    connectTimeout: const Duration(seconds: 15),
                    receiveTimeout: const Duration(seconds: 15),
                    headers: {'User-Agent': 'PrivateDeploy/1.0'},
                  ),
                );
                final resp = await dio.get(url);
                final config =
                    SubscriptionParser.parseResponseDataToSingboxConfig(
                  resp.data,
                );
                if (config == null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Failed to parse subscription'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                  return;
                }

                final profileName = name.isNotEmpty
                    ? name
                    : 'Sub ${DateTime.now().toString().substring(0, 16)}';
                final provider = context.read<ProfileProvider>();
                final success = await provider.createProfile(
                  name: profileName,
                  subscriptionUrl: url,
                  content: config,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        success ? 'Imported successfully' : 'Failed to import',
                      ),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Network error: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final nameController = TextEditingController();
    final configController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Profile'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Profile Name',
                    hintText: 'e.g. My VPN Config',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a profile name';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 16.h),
                TextFormField(
                  controller: configController,
                  decoration: const InputDecoration(
                    labelText: 'sing-box JSON Config',
                    hintText: 'Paste sing-box configuration JSON here...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 8,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.sp,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) {
                return;
              }

              Navigator.pop(context);
              final provider = context.read<ProfileProvider>();
              final success = await provider.createProfile(
                name: nameController.text,
                content: configController.text,
              );

              if (!context.mounted) {
                return;
              }

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    success
                        ? 'Profile created successfully'
                        : provider.error ?? 'Failed to create profile',
                  ),
                  backgroundColor: success ? Colors.green : Colors.red,
                ),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showApiKeyDialog(BuildContext context) {
    final provider = context.read<CloudProvider>();
    final controller = TextEditingController(text: provider.apiKey ?? '');
    var isSaving = false;
    String? dialogError;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Cloud API Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'Enter your cloud provider API key',
                  border: OutlineInputBorder(),
                ),
                enabled: !isSaving,
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 12),
                Text(
                  dialogError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isSaving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      setState(() {
                        isSaving = true;
                        dialogError = null;
                      });

                      final success =
                          await provider.setApiKey(controller.text.trim());
                      if (!context.mounted) {
                        return;
                      }

                      if (success) {
                        Navigator.pop(context);
                        _bootstrapTriggered = false;
                        await _refreshAll(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('API key saved and verified'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      } else {
                        setState(() {
                          dialogError = provider.error;
                          isSaving = false;
                        });
                      }
                    },
              child: isSaving
                  ? const Text('Verifying...')
                  : const Text('Verify & Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateCloudDialog(BuildContext context) {
    final provider = context.read<CloudProvider>();
    final labelController = TextEditingController();
    String? selectedRegion;
    String? selectedPlan;

    provider.loadRegions();
    provider.loadPlans();

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => Consumer<CloudProvider>(
          builder: (context, provider, _) => AlertDialog(
            title: const Text('Deploy Node'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: labelController,
                    decoration: const InputDecoration(
                      labelText: 'Node Name (Optional)',
                      hintText: 'Auto-generate if left blank',
                    ),
                  ),
                  SizedBox(height: 16.h),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRegion,
                    decoration: const InputDecoration(labelText: 'Region'),
                    isExpanded: true,
                    items: provider.regions
                        .map(
                          (region) => DropdownMenuItem(
                            value: region.id,
                            child: Text(region.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => selectedRegion = value),
                  ),
                  SizedBox(height: 16.h),
                  DropdownButtonFormField<String>(
                    initialValue: selectedPlan,
                    decoration: const InputDecoration(labelText: 'Plan'),
                    isExpanded: true,
                    items: provider.plans
                        .where(
                          (plan) =>
                              selectedRegion == null ||
                              plan.locations.contains(selectedRegion),
                        )
                        .map(
                          (plan) => DropdownMenuItem(
                            value: plan.id,
                            child: Text(plan.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => selectedPlan = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (selectedRegion == null || selectedPlan == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please select region and plan'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                    return;
                  }

                  Navigator.pop(context);
                  final success = await provider.createInstance(
                    region: selectedRegion!,
                    plan: selectedPlan!,
                    label: labelController.text,
                  );

                  if (!dialogContext.mounted) {
                    return;
                  }

                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text(
                        success
                            ? 'Node deploying... It takes 3-5 minutes.'
                            : provider.error ?? 'Failed to create',
                      ),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                },
                child: const Text('Deploy'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteCloudNode(BuildContext context, CloudInstance instance) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Node'),
        content: Text(
          'Delete "${instance.label}"?\n\nThis will destroy the server permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(context);
              final cloudProvider = context.read<CloudProvider>();
              final profileProvider = context.read<ProfileProvider>();
              final vpnProvider = context.read<VpnProvider>();
              final profileName = _cloudProfileName(instance);
              final linkedProfile =
                  profileProvider.getProfileByName(profileName);
              final shouldDisconnect = linkedProfile != null &&
                  profileProvider.activeProfile?.id == linkedProfile.id &&
                  vpnProvider.status != VpnStatus.disconnected;

              final success = await cloudProvider.deleteInstance(instance.id);
              var disconnectSuccess = true;
              var profileCleanupSuccess = true;

              if (success && shouldDisconnect) {
                disconnectSuccess = await vpnProvider.disconnect();
              }

              if (success) {
                profileCleanupSuccess =
                    await profileProvider.deleteProfileByName(profileName);
              }

              if (!context.mounted) {
                return;
              }

              final operationSucceeded =
                  success && disconnectSuccess && profileCleanupSuccess;
              final message = success
                  ? operationSucceeded
                      ? 'Node deleted'
                      : 'Node deleted, but local cleanup needs attention'
                  : cloudProvider.error ?? 'Failed to delete';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(message),
                  backgroundColor: operationSucceeded
                      ? Colors.green
                      : success
                          ? Colors.orange
                          : Colors.red,
                ),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  static bool _isCloudManagedProfile(Profile profile) {
    return profile.name.startsWith('Cloud: ');
  }

  static String _cloudProfileName(CloudInstance instance) {
    return 'Cloud: ${instance.label}';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
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

  Future<void> _handleConnect(
    BuildContext context,
    VpnProvider vpnProvider,
  ) async {
    await _connectSelectedProfile(
      context,
      vpnProvider,
      context.read<ProfileProvider>(),
      successMessage: 'VPN connected successfully',
    );
  }

  Future<void> _handleDisconnect(
    BuildContext context,
    VpnProvider vpnProvider,
  ) async {
    final success = await vpnProvider.disconnect();
    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'VPN disconnected successfully'
              : vpnProvider.error ?? 'Failed to disconnect VPN',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _handleRestart(
    BuildContext context,
    VpnProvider vpnProvider,
  ) async {
    await _connectSelectedProfile(
      context,
      vpnProvider,
      context.read<ProfileProvider>(),
      forceReconnect: true,
      successMessage: 'VPN restarted successfully',
    );
  }

  Future<void> _connectSelectedProfile(
    BuildContext context,
    VpnProvider vpnProvider,
    ProfileProvider profileProvider, {
    bool forceReconnect = false,
    required String successMessage,
  }) async {
    if (vpnProvider.isLoading ||
        vpnProvider.status == VpnStatus.connecting ||
        vpnProvider.status == VpnStatus.disconnecting) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('VPN is busy, please wait a moment'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final activeProfile = profileProvider.activeProfile;
    final configJson = profileProvider.getActiveConfigJson();
    if (configJson == null || configJson.isEmpty) {
      final cloudProvider = context.read<CloudProvider>();
      final readyCloudNodes = _connectableCloudInstances(cloudProvider);
      if (readyCloudNodes.length == 1) {
        await _useCloudNode(context, readyCloudNodes.first, cloudProvider);
        return;
      }
      if (readyCloudNodes.length > 1) {
        final selectedNode =
            await _pickCloudNodeForConnect(context, readyCloudNodes);
        if (selectedNode != null && context.mounted) {
          await _useCloudNode(context, selectedNode, cloudProvider);
        }
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cloudProvider.instances.isNotEmpty
                ? 'These cloud nodes are visible, but this device does not have their connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.'
                : 'No ready node selected yet. Choose a cloud node below or create/import a profile first.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final configError = _validateSingboxConfig(configJson);
    if (configError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(configError),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (vpnProvider.status == VpnStatus.connected) {
      final disconnected = await vpnProvider.disconnect();
      if (!disconnected) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                vpnProvider.error ?? 'Failed to switch active VPN node',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      if (!context.mounted) {
        return;
      }
      if (!forceReconnect) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    final connected = await vpnProvider.connect(
      configJson: configJson,
      profileName: activeProfile?.name,
    );
    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          connected
              ? successMessage
              : vpnProvider.error ?? 'Failed to connect VPN',
        ),
        backgroundColor: connected ? Colors.green : Colors.red,
      ),
    );
  }
}
