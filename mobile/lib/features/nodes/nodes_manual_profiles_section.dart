import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';
import '../profiles/profile_provider.dart';
import 'nodes_widgets.dart';

class NodesManualProfilesSection extends StatelessWidget {
  final List<Profile> profiles;
  final String? activeProfileId;
  final bool isConnected;
  final Map<String, ProfileSpeedResult> speedResults;
  final ValueChanged<Profile> onActivate;
  final ValueChanged<Profile> onSpeedTest;
  final ValueChanged<Profile> onView;
  final ValueChanged<Profile> onEdit;
  final ValueChanged<Profile> onDelete;

  const NodesManualProfilesSection({
    Key? key,
    required this.profiles,
    required this.activeProfileId,
    this.isConnected = false,
    this.speedResults = const {},
    required this.onActivate,
    required this.onSpeedTest,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodesSectionHeader(
          title: l10n.manualProfiles,
          count: profiles.length,
        ),
        SizedBox(height: 8.h),
        ...profiles.map(
          (profile) => NodesProfileCard(
            profile: profile,
            isActive: profile.id == activeProfileId,
            isConnected: profile.id == activeProfileId && isConnected,
            createdAtLabel: _formatDate(profile.createdAt),
            speedResult: speedResults[profile.id],
            onActivate: () => onActivate(profile),
            onSpeedTest: () => onSpeedTest(profile),
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
