import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'cloud_provider.dart';
import 'cloud_models.dart';
import '../profiles/profile_provider.dart';
import '../../shared/widgets/empty_view.dart';
import '../../shared/widgets/error_view.dart';

class CloudScreen extends StatefulWidget {
  const CloudScreen({Key? key}) : super(key: key);

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  bool _bootstrapTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapCloudState();
    });
  }

  void _bootstrapCloudState() {
    if (!mounted) {
      return;
    }

    final provider = context.read<CloudProvider>();
    if (_bootstrapTriggered) {
      return;
    }

    _bootstrapTriggered = true;
    Future<void>(() async {
      await provider.refreshCloudConfig();
      if (provider.hasApiKey) {
        await provider.loadInstances();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud Nodes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.key),
            onPressed: () => _showApiKeyDialog(context),
            tooltip: 'API Key',
          ),
          Consumer<CloudProvider>(
            builder: (context, provider, _) {
              if (!provider.hasApiKey) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => provider.loadInstances(),
              );
            },
          ),
        ],
      ),
      body: Consumer<CloudProvider>(
        builder: (context, provider, _) {
          if (!_bootstrapTriggered) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _bootstrapCloudState();
            });
          }

          if (!provider.hasApiKey) {
            return _buildNoApiKey(context);
          }

          if (provider.isLoading && provider.instances.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.error != null && provider.instances.isEmpty) {
            return ErrorView(
              message: provider.error!,
              onRetry: () => provider.loadInstances(),
            );
          }

          if (provider.instances.isEmpty) {
            return const EmptyView(
              icon: Icons.cloud_off,
              title: 'No cloud nodes',
              message: 'Deploy your first proxy node',
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.loadInstances(),
            child: ListView.builder(
              padding: EdgeInsets.all(16.w),
              itemCount: provider.instances.length,
              itemBuilder: (context, index) {
                final instance = provider.instances[index];
                return _buildInstanceCard(context, instance, provider);
              },
            ),
          );
        },
      ),
      floatingActionButton: Consumer<CloudProvider>(
        builder: (context, provider, _) {
          if (!provider.hasApiKey) return const SizedBox.shrink();
          return FloatingActionButton(
            onPressed: () => _showCreateDialog(context),
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _buildNoApiKey(BuildContext context) {
    return EmptyView(
      icon: Icons.vpn_key,
      title: 'Cloud API Key Required',
      message: 'Save your cloud provider API key before deploying nodes.',
      onAction: () => _showApiKeyDialog(context),
      actionLabel: 'Set API Key',
    );
  }

  Widget _buildInstanceCard(
      BuildContext context, CloudInstance instance, CloudProvider provider) {
    final isActive = instance.isActive;
    final hasIp = instance.hasIp;
    final hasNodeInfo = instance.nodeInfo != null;

    return Card(
      margin: EdgeInsets.only(bottom: 12.h),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: isActive ? Colors.green : Colors.orange,
              child: Icon(
                isActive ? Icons.check_circle : Icons.hourglass_empty,
                color: Colors.white,
              ),
            ),
            title: Text(instance.label,
                style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 4.h),
                Text('Status: ${instance.status} | Region: ${instance.region}'),
                if (hasIp) Text('IP: ${instance.ipv4}'),
                if (hasNodeInfo)
                  Text('Protocols: SS / Hy2 / VLESS / Trojan',
                      style:
                          TextStyle(color: Colors.green[700], fontSize: 12.sp)),
              ],
            ),
          ),
          if (isActive && hasIp && hasNodeInfo)
            Padding(
              padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 12.h),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _importAsProfile(context, instance, provider),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Import as Profile'),
                    ),
                  ),
                  SizedBox(width: 8.w),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _confirmDelete(context, instance),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 12.h),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _confirmDelete(context, instance),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _importAsProfile(BuildContext context, CloudInstance instance,
      CloudProvider cloudProvider) async {
    final config = cloudProvider.generateNodeConfig(instance);
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Node not ready yet'),
            backgroundColor: Colors.orange),
      );
      return;
    }

    final profileProvider = context.read<ProfileProvider>();
    final success = await profileProvider.createProfile(
      name: 'Cloud: ${instance.label}',
      content: config,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Profile created and activated'
              : 'Failed to create profile'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _showApiKeyDialog(BuildContext context) {
    final provider = context.read<CloudProvider>();
    final controller = TextEditingController(
      text: provider.apiKey ?? '',
    );
    bool isSaving = false;
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
                maxLines: 1,
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

                      final success = await provider.setApiKey(controller.text.trim());
                      if (context.mounted) {
                        if (success) {
                          Navigator.pop(context);
                          _bootstrapTriggered = false;
                          provider.loadInstances();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('API key saved and verified'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        } else {
                          setState(() {
                            dialogError = provider.error;
                          });
                          setState(() {
                            isSaving = false;
                          });
                        }
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

  void _showCreateDialog(BuildContext context) {
    final provider = context.read<CloudProvider>();
    final labelController = TextEditingController();
    String? selectedRegion;
    String? selectedPlan;

    // Load regions and plans
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
                      labelText: 'Node Name',
                      hintText: 'e.g. Tokyo-1',
                    ),
                  ),
                  SizedBox(height: 16.h),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRegion,
                    decoration: const InputDecoration(labelText: 'Region'),
                    isExpanded: true,
                    items: provider.regions
                        .map((r) => DropdownMenuItem(
                            value: r.id, child: Text(r.displayName)))
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
                        .where((p) =>
                            selectedRegion == null ||
                            p.locations.contains(selectedRegion))
                        .map((p) => DropdownMenuItem(
                            value: p.id, child: Text(p.displayName)))
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
                  if (labelController.text.isEmpty ||
                      selectedRegion == null ||
                      selectedPlan == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Please fill all fields'),
                          backgroundColor: Colors.orange),
                    );
                    return;
                  }

                  Navigator.pop(context);
                  final success = await provider.createInstance(
                    region: selectedRegion!,
                    plan: selectedPlan!,
                    label: labelController.text,
                  );

                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(
                        content: Text(success
                            ? 'Node deploying... It takes 3-5 minutes.'
                            : provider.error ?? 'Failed to create'),
                        backgroundColor: success ? Colors.green : Colors.red,
                      ),
                    );
                  }
                },
                child: const Text('Deploy'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, CloudInstance instance) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Node'),
        content: Text(
            'Delete "${instance.label}"?\n\nThis will destroy the server permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(context);
              final success = await context
                  .read<CloudProvider>()
                  .deleteInstance(instance.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content:
                        Text(success ? 'Node deleted' : 'Failed to delete'),
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
