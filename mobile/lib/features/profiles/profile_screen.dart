import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'profile_provider.dart';
import '../../core/subscription/parser.dart';
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
              message:
                  'Create a profile with sing-box JSON config to get started',
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
                          backgroundColor:
                              isActive ? Colors.green : Colors.grey,
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
                            SizedBox(height: 4.h),
                            Text(
                              'Created: ${_formatDate(profile.createdAt)}',
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
                                  Text('Delete',
                                      style: TextStyle(color: Colors.red)),
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'import',
            onPressed: () => _showImportDialog(context),
            child: const Icon(Icons.link),
          ),
          SizedBox(height: 8.h),
          FloatingActionButton(
            heroTag: 'create',
            onPressed: () => _showCreateDialog(context),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
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
              SizedBox(height: 8.h),
              Text(
                'Supports: sing-box JSON, base64 URI list (ss/vless/trojan/hy2/vmess)',
                style: TextStyle(fontSize: 11.sp, color: Colors.grey),
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
              if (url.isEmpty) return;

              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Fetching subscription...')),
              );

              try {
                final dio = Dio(BaseOptions(
                  connectTimeout: const Duration(seconds: 15),
                  receiveTimeout: const Duration(seconds: 15),
                  headers: {'User-Agent': 'PrivateDeploy/1.0'},
                ));
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
                          backgroundColor: Colors.red),
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
                      content: Text(success
                          ? 'Imported successfully'
                          : 'Failed to import'),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('Network error: $e'),
                        backgroundColor: Colors.red),
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
              if (formKey.currentState!.validate()) {
                Navigator.pop(context);
                final provider = context.read<ProfileProvider>();
                final success = await provider.createProfile(
                  name: nameController.text,
                  content: configController.text,
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
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Profile'),
        content: Form(
          key: formKey,
          child: TextFormField(
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
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? 'Profile renamed'
                          : provider.error ?? 'Failed to rename'),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _viewProfileContent(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final content = await provider.getProfileContent(profile.id);

    if (!context.mounted) return;

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

  void _activateProfile(BuildContext context, Profile profile) async {
    final provider = context.read<ProfileProvider>();
    final success = await provider.activateProfile(profile.id);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Profile activated'
              : provider.error ?? 'Failed to activate'),
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
                        ? 'Profile deleted'
                        : provider.error ?? 'Failed to delete'),
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
            hintText: 'Paste sing-box JSON configuration here...',
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
          content: Text(
              success ? 'Config saved' : provider.error ?? 'Failed to save'),
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
