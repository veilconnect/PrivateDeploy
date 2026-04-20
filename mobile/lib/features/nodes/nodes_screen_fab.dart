import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import 'nodes_test_keys.dart';

class NodesScreenFab extends StatelessWidget {
  final VoidCallback onImportProfile;
  final VoidCallback onCreateProfile;

  const NodesScreenFab({
    Key? key,
    required this.onImportProfile,
    required this.onCreateProfile,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          key: NodesTestKeys.importProfileFab,
          heroTag: 'import_profile',
          tooltip: l10n.importProfile,
          onPressed: onImportProfile,
          child: const Icon(Icons.link),
        ),
        SizedBox(height: 8.h),
        FloatingActionButton(
          key: NodesTestKeys.createProfileFab,
          heroTag: 'create_profile',
          tooltip: l10n.createProfileTooltip,
          onPressed: onCreateProfile,
          child: const Icon(Icons.add),
        ),
      ],
    );
  }
}
