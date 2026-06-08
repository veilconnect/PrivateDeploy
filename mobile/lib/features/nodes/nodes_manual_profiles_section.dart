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
    final orderedProfiles = List<Profile>.from(profiles)
      ..sort((a, b) => _compareProfiles(a, b, activeProfileId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodesSectionHeader(
          title: l10n.manualProfiles,
          subtitle: l10n.manualProfilesDesc,
          count: profiles.length,
        ),
        SizedBox(height: 8.h),
        ...orderedProfiles.map(
          (profile) => NodesProfileCard(
            profile: profile,
            isActive: profile.id == activeProfileId,
            isConnected: profile.id == activeProfileId && isConnected,
            timestampLabel: _timestampLabel(l10n, profile),
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

int _compareProfiles(Profile a, Profile b, String? activeProfileId) {
  final aIsActive = a.id == activeProfileId;
  final bIsActive = b.id == activeProfileId;
  if (aIsActive != bIsActive) {
    return aIsActive ? -1 : 1;
  }

  final aRecency = a.lastUpdated ?? a.updatedAt;
  final bRecency = b.lastUpdated ?? b.updatedAt;
  final recencyPriority = bRecency.compareTo(aRecency);
  if (recencyPriority != 0) {
    return recencyPriority;
  }

  final createdAtPriority = b.createdAt.compareTo(a.createdAt);
  if (createdAtPriority != 0) {
    return createdAtPriority;
  }

  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

String _timestampLabel(AppLocalizations l10n, Profile profile) {
  final lastUpdated = profile.lastUpdated ?? profile.updatedAt;
  final wasUpdated = profile.lastUpdated != null ||
      profile.updatedAt
          .isAfter(profile.createdAt.add(const Duration(minutes: 1)));
  if (wasUpdated) {
    return l10n.lastUpdated(_formatDate(lastUpdated));
  }
  return l10n.createdAt(_formatDate(profile.createdAt));
}

String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
