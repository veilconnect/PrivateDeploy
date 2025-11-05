import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'profile_provider.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/empty_view.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({Key? key}) : super(key: key);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ProfileProvider>();
      provider.loadProfiles();
      provider.loadActiveProfile();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration Profiles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<ProfileProvider>().loadProfiles();
            },
          ),
        ],
      ),
      body: Consumer<ProfileProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading && provider.profiles.isEmpty) {
            return const LoadingIndicator(message: 'Loading profiles...');
          }

          if (provider.error != null && provider.profiles.isEmpty) {
            return ErrorView(
              message: provider.error!,
              onRetry: () => provider.loadProfiles(),
            );
          }

          if (provider.profiles.isEmpty) {
            return EmptyView(
              icon: Icons.description_outlined,
              title: 'No Profiles',
              message: 'Create a configuration profile to get started',
              onAction: () => _showCreateDialog(context),
              actionLabel: 'Create Profile',
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.loadProfiles(),
            child: ListView.builder(
              padding: EdgeInsets.all(16.w),
              itemCount: provider.profiles.length,
              itemBuilder: (context, index) {
                final profile = provider.profiles[index];
                final isActive = profile.id == provider.activeProfile?.id;

                return Card(
                  margin: EdgeInsets.only(bottom: 12.h),
                  child: Column(
                    children: [
                      ListTile(
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
                            if (isActive)
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8.w,
                                  vertical: 4.h,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  borderRadius: BorderRadius.circular(12.r),
                                ),
                                child: Text(
                                  'ACTIVE',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.sp,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (profile.subscriptionUrl != null) ...[
                              SizedBox(height: 4.h),
                              Text(
                                'Subscription: ${profile.subscriptionUrl}',
                                style: TextStyle(
                                  fontSize: 12.sp,
                                  color: Colors.grey[600],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            SizedBox(height: 4.h),
                            Text(
                              'Created: ${_formatDate(profile.createdAt)}',
                              style: TextStyle(
                                fontSize: 12.sp,
                                color: Colors.grey[600],
                              ),
                            ),
                            if (profile.lastUpdated != null)
                              Text(
                                'Last Updated: ${_formatDate(profile.lastUpdated!)}',
                                style: TextStyle(
                                  fontSize: 12.sp,
                                  color: Colors.grey[600],
                                ),
                              ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            switch (value) {
                              case 'activate':
                                _activateProfile(context, profile);
                                break;
                              case 'edit':
                                _showEditDialog(context, profile);
                                break;
                              case 'view':
                                _viewProfileContent(context, profile);
                                break;
                              case 'update':
                                _updateSubscription(context, profile);
                                break;
                              case 'delete':
                                _confirmDelete(context, profile);
                                break;
                            }
                          },
                          itemBuilder: (context) => [
                            if (!isActive)
                              const PopupMenuItem(
                                value: 'activate',
                                child: Row(
                                  children: [
                                    Icon(Icons.check_circle),
                                    SizedBox(width: 8),
                                    Text('Activate'),
                                  ],
                                ),
                              ),
                            const PopupMenuItem(
                              value: 'view',
                              child: Row(
                                children: [
                                  Icon(Icons.visibility),
                                  SizedBox(width: 8),
                                  Text('View Content'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  Icon(Icons.edit),
                                  SizedBox(width: 8),
                                  Text('Edit'),
                                ],
                              ),
                            ),
                            if (profile.subscriptionUrl != null)
                              const PopupMenuItem(
                                value: 'update',
                                child: Row(
                                  children: [
                                    Icon(Icons.refresh),
                                    SizedBox(width: 8),
                                    Text('Update Subscription'),
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
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _showCreateDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Profile'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  hintText: 'Enter profile name',
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
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL (Optional)',
                  hintText: 'Enter subscription URL',
                ),
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
              if (formKey.currentState!.validate()) {
                Navigator.pop(context);
                final provider = context.read<ProfileProvider>();
                final success = await provider.createProfile(
                  name: nameController.text,
                  subscriptionUrl: urlController.text.isEmpty ? null : urlController.text,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? 'Profile created successfully'
                          : provider.error ?? 'Failed to create profile'),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, Profile profile) {
    final nameController = TextEditingController(text: profile.name);
    final urlController = TextEditingController(text: profile.subscriptionUrl ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Profile'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
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
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL',
                ),
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
              if (formKey.currentState!.validate()) {
                Navigator.pop(context);
                final provider = context.read<ProfileProvider>();
                final success = await provider.updateProfile(
                  id: profile.id,
                  name: nameController.text,
                  subscriptionUrl: urlController.text.isEmpty ? null : urlController.text,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? 'Profile updated successfully'
                          : provider.error ?? 'Failed to update profile'),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _viewProfileContent(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final content = await provider.getProfileContent(profile.id);

    if (!context.mounted) return;

    if (content != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ProfileContentScreen(
            profile: profile,
            content: content,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.error ?? 'Failed to load profile content'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _activateProfile(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final success = await provider.activateProfile(profile.id);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Profile activated successfully'
              : provider.error ?? 'Failed to activate profile'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _updateSubscription(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Updating subscription...')),
    );

    final success = await provider.updateSubscription(profile.id);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Subscription updated successfully'
              : provider.error ?? 'Failed to update subscription'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _confirmDelete(BuildContext context, Profile profile) {
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

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success
                        ? 'Profile deleted successfully'
                        : provider.error ?? 'Failed to delete profile'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

/// Profile content viewer/editor screen
class ProfileContentScreen extends StatefulWidget {
  final Profile profile;
  final String content;

  const ProfileContentScreen({
    Key? key,
    required this.profile,
    required this.content,
  }) : super(key: key);

  @override
  State<ProfileContentScreen> createState() => _ProfileContentScreenState();
}

class _ProfileContentScreenState extends State<ProfileContentScreen> {
  late TextEditingController _contentController;
  bool _isEditing = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.content);
    _contentController.addListener(() {
      setState(() {
        _hasChanges = _contentController.text != widget.content;
      });
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            icon: Icon(_isEditing ? Icons.visibility : Icons.edit),
            onPressed: () {
              setState(() {
                _isEditing = !_isEditing;
              });
            },
          ),
          if (_hasChanges && _isEditing)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveContent,
            ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(16.w),
        child: TextField(
          controller: _contentController,
          readOnly: !_isEditing,
          maxLines: null,
          expands: true,
          decoration: InputDecoration(
            border: _isEditing ? const OutlineInputBorder() : InputBorder.none,
            hintText: 'Profile configuration content...',
          ),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 14.sp,
          ),
        ),
      ),
    );
  }

  Future<void> _saveContent() async {
    final provider = context.read<ProfileProvider>();
    final success = await provider.saveProfileContent(
      widget.profile.id,
      _contentController.text,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Profile saved successfully'
              : provider.error ?? 'Failed to save profile'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );

      if (success) {
        setState(() {
          _hasChanges = false;
          _isEditing = false;
        });
      }
    }
  }
}
