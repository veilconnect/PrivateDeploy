import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../profiles/profile_provider.dart';
import 'nodes_widgets.dart';

class NodesManualProfilesSection extends StatelessWidget {
  final List<Profile> profiles;
  final String? activeProfileId;
  final ValueChanged<Profile> onActivate;
  final ValueChanged<Profile> onView;
  final ValueChanged<Profile> onEdit;
  final ValueChanged<Profile> onDelete;

  const NodesManualProfilesSection({
    Key? key,
    required this.profiles,
    required this.activeProfileId,
    required this.onActivate,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodesSectionHeader(
          title: 'Manual Profiles',
          subtitle: 'Local configs and imported subscriptions',
          count: profiles.length,
        ),
        SizedBox(height: 8.h),
        ...profiles.map(
          (profile) => NodesProfileCard(
            profile: profile,
            isActive: profile.id == activeProfileId,
            createdAtLabel: _formatDate(profile.createdAt),
            onActivate: () => onActivate(profile),
            onView: () => onView(profile),
            onEdit: () => onEdit(profile),
            onDelete: () => onDelete(profile),
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
