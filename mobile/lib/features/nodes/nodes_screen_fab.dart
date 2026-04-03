import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class NodesScreenFab extends StatelessWidget {
  final bool showDeployNode;
  final VoidCallback onDeployNode;
  final VoidCallback onImportProfile;
  final VoidCallback onCreateProfile;

  const NodesScreenFab({
    Key? key,
    required this.showDeployNode,
    required this.onDeployNode,
    required this.onImportProfile,
    required this.onCreateProfile,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDeployNode)
          FloatingActionButton.small(
            heroTag: 'deploy_node',
            tooltip: 'Deploy cloud node',
            onPressed: onDeployNode,
            child: const Icon(Icons.cloud_upload),
          ),
        if (showDeployNode) SizedBox(height: 8.h),
        FloatingActionButton.small(
          heroTag: 'import_profile',
          tooltip: 'Import profile',
          onPressed: onImportProfile,
          child: const Icon(Icons.link),
        ),
        SizedBox(height: 8.h),
        FloatingActionButton(
          heroTag: 'create_profile',
          tooltip: 'Create profile',
          onPressed: onCreateProfile,
          child: const Icon(Icons.add),
        ),
      ],
    );
  }
}
