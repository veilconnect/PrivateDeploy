import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'cloud_provider.dart';

class CloudScreen extends StatefulWidget {
  const CloudScreen({Key? key}) : super(key: key);

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CloudProvider>().loadInstances();
      context.read<CloudProvider>().loadProviders();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud Servers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<CloudProvider>().loadInstances();
            },
          ),
        ],
      ),
      body: Consumer<CloudProvider>(
        builder: (context, cloudProvider, _) {
          if (cloudProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (cloudProvider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64.w, color: Colors.red),
                  SizedBox(height: 16.h),
                  Text(
                    'Error: ${cloudProvider.error}',
                    style: TextStyle(fontSize: 16.sp),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 24.h),
                  ElevatedButton(
                    onPressed: () {
                      cloudProvider.loadInstances();
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (cloudProvider.instances.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 64.w, color: Colors.grey),
                  SizedBox(height: 16.h),
                  Text(
                    'No cloud servers',
                    style: TextStyle(
                      fontSize: 20.sp,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8.h),
                  Text(
                    'Create your first server',
                    style: TextStyle(
                      fontSize: 16.sp,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: EdgeInsets.all(16.w),
            itemCount: cloudProvider.instances.length,
            itemBuilder: (context, index) {
              final instance = cloudProvider.instances[index];
              return Card(
                margin: EdgeInsets.only(bottom: 12.h),
                child: ListTile(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16.w,
                    vertical: 8.h,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: _getStatusColor(instance.status),
                    child: Icon(
                      _getStatusIcon(instance.status),
                      color: Colors.white,
                    ),
                  ),
                  title: Text(
                    instance.label,
                    style: TextStyle(
                      fontSize: 16.sp,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 4.h),
                      Text('Status: ${instance.status}'),
                      Text('Region: ${instance.region}'),
                      if (instance.ipv4 != null)
                        Text('IP: ${instance.ipv4}'),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _confirmDelete(context, instance),
                  ),
                  onTap: () => _showInstanceDetails(context, instance),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
      case 'running':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'error':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'active':
      case 'running':
        return Icons.check_circle;
      case 'pending':
        return Icons.hourglass_empty;
      case 'error':
        return Icons.error;
      default:
        return Icons.cloud;
    }
  }

  void _showInstanceDetails(BuildContext context, CloudInstance instance) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(instance.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('ID', instance.id),
            _buildDetailRow('Status', instance.status),
            _buildDetailRow('Region', instance.region),
            _buildDetailRow('Plan', instance.plan),
            if (instance.ipv4 != null)
              _buildDetailRow('IPv4', instance.ipv4!),
            if (instance.ipv6 != null)
              _buildDetailRow('IPv6', instance.ipv6!),
            _buildDetailRow(
              'Created',
              instance.createdAt.toString().substring(0, 19),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80.w,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14.sp,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 14.sp),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, CloudInstance instance) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Server'),
        content: Text(
          'Are you sure you want to delete "${instance.label}"?\n\nThis action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final success = await context
                  .read<CloudProvider>()
                  .deleteInstance(instance.id);
              
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? 'Server deleted successfully'
                          : 'Failed to delete server',
                    ),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final labelController = TextEditingController();
    String? selectedRegion;
    String? selectedPlan;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create Server'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(
                    labelText: 'Server Name',
                    hintText: 'My Server',
                  ),
                ),
                SizedBox(height: 16.h),
                DropdownButtonFormField<String>(
                  value: selectedRegion,
                  decoration: const InputDecoration(labelText: 'Region'),
                  items: const [
                    DropdownMenuItem(value: 'ewr', child: Text('New York')),
                    DropdownMenuItem(value: 'lax', child: Text('Los Angeles')),
                    DropdownMenuItem(value: 'lhr', child: Text('London')),
                    DropdownMenuItem(value: 'sgp', child: Text('Singapore')),
                  ],
                  onChanged: (value) {
                    setState(() => selectedRegion = value);
                  },
                ),
                SizedBox(height: 16.h),
                DropdownButtonFormField<String>(
                  value: selectedPlan,
                  decoration: const InputDecoration(labelText: 'Plan'),
                  items: const [
                    DropdownMenuItem(
                      value: 'vc2-1c-1gb',
                      child: Text('1 CPU, 1GB RAM - \$6/mo'),
                    ),
                    DropdownMenuItem(
                      value: 'vc2-1c-2gb',
                      child: Text('1 CPU, 2GB RAM - \$12/mo'),
                    ),
                    DropdownMenuItem(
                      value: 'vc2-2c-4gb',
                      child: Text('2 CPU, 4GB RAM - \$24/mo'),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() => selectedPlan = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                if (labelController.text.isEmpty ||
                    selectedRegion == null ||
                    selectedPlan == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please fill all fields'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }

                Navigator.pop(context);
                
                final success = await context.read<CloudProvider>().createInstance(
                  region: selectedRegion!,
                  plan: selectedPlan!,
                  label: labelController.text,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        success
                            ? 'Server creation started'
                            : 'Failed to create server',
                      ),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}
