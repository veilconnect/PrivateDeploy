import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';

class NodesSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int count;

  const NodesSectionHeader({
    Key? key,
    required this.title,
    this.subtitle,
    required this.count,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
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
              if (subtitle != null) ...[
                SizedBox(height: 4.h),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: Colors.grey[600],
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        Container(
          margin: EdgeInsets.only(left: 12.w),
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
          decoration: BoxDecoration(
            color: const Color(0xFF1452CC).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999.r),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: const Color(0xFF1452CC),
              fontSize: 12.sp,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class NodesInlineInfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;
  final Color accentColor;

  const NodesInlineInfoCard({
    Key? key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.accentColor = const Color(0xFF3F5E88),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46.w,
              height: 46.w,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14.r),
              ),
              child: Icon(icon, size: 24.sp, color: accentColor),
            ),
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
            if ((actionLabel != null && onAction != null) ||
                (secondaryActionLabel != null &&
                    onSecondaryAction != null)) ...[
              SizedBox(height: 14.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  if (actionLabel != null && onAction != null)
                    FilledButton(
                        onPressed: onAction, child: Text(actionLabel!)),
                  if (secondaryActionLabel != null && onSecondaryAction != null)
                    OutlinedButton(
                      onPressed: onSecondaryAction,
                      child: Text(secondaryActionLabel!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class NodesInlineBanner extends StatelessWidget {
  const NodesInlineBanner({
    Key? key,
    required this.icon,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.accentColor = const Color(0xFF1452CC),
  }) : super(key: key);

  final IconData icon;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: accentColor.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38.w,
                height: 38.w,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Icon(icon, size: 20.sp, color: accentColor),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 12.sp,
                        color: Colors.grey[700],
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((primaryLabel != null && onPrimary != null) ||
              (secondaryLabel != null && onSecondary != null)) ...[
            SizedBox(height: 12.h),
            Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                if (primaryLabel != null && onPrimary != null)
                  FilledButton(
                    onPressed: onPrimary,
                    child: Text(primaryLabel!),
                  ),
                if (secondaryLabel != null && onSecondary != null)
                  OutlinedButton(
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class NodesStatusChip extends StatelessWidget {
  final String text;
  final Color color;

  const NodesStatusChip({
    Key? key,
    required this.text,
    required this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999.r),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10.sp,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class NodesMetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? hint;
  final Color color;
  final bool preferVertical;

  const NodesMetricTile({
    Key? key,
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    required this.color,
    this.preferVertical = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = preferVertical || constraints.maxWidth < 150.w;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(color: color.withValues(alpha: 0.12)),
          ),
          child: isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MetricTileIcon(color: color, icon: icon),
                    SizedBox(height: 10.h),
                    _MetricTileCopy(
                      label: label,
                      value: value,
                      hint: hint,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MetricTileIcon(color: color, icon: icon),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: _MetricTileCopy(
                        label: label,
                        value: value,
                        hint: hint,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _MetricTileIcon extends StatelessWidget {
  const _MetricTileIcon({
    required this.color,
    required this.icon,
  });

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34.w,
      height: 34.w,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Icon(icon, size: 18.sp, color: color),
    );
  }
}

class _MetricTileCopy extends StatelessWidget {
  const _MetricTileCopy({
    required this.label,
    required this.value,
    required this.hint,
  });

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.sp,
            color: Colors.grey[700],
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 4.h),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14.sp,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (hint != null) ...[
          SizedBox(height: 2.h),
          Text(
            hint!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.sp,
              color: Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }
}

class NodesJourneyCard extends StatelessWidget {
  const NodesJourneyCard({
    Key? key,
    required this.eyebrow,
    required this.title,
    required this.message,
    required this.icon,
    required this.color,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.steps = const [],
  }) : super(key: key);

  final String eyebrow;
  final String title;
  final String message;
  final IconData icon;
  final Color color;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final List<NodesJourneyStep> steps;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28.r),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF081223),
              Color(0xFF0F2B57),
              Color(0xFF1452CC),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -48.h,
              right: -24.w,
              child: Container(
                width: 180.w,
                height: 180.w,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: -56.h,
              left: -20.w,
              child: Container(
                width: 150.w,
                height: 150.w,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(20.w),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999.r),
                    ),
                    child: Text(
                      eyebrow,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(height: 16.h),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 24.sp,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.1,
                              ),
                            ),
                            SizedBox(height: 10.h),
                            Text(
                              message,
                              style: TextStyle(
                                fontSize: 13.sp,
                                color: Colors.white.withValues(alpha: 0.84),
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Container(
                        width: 58.w,
                        height: 58.w,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20.r),
                        ),
                        child: Icon(icon, color: Colors.white, size: 30.sp),
                      ),
                    ],
                  ),
                  if (steps.isNotEmpty) ...[
                    SizedBox(height: 18.h),
                    Wrap(
                      spacing: 8.w,
                      runSpacing: 8.h,
                      children: [
                        for (var index = 0; index < steps.length; index++)
                          _NodesJourneyStepChip(
                            index: index,
                            step: steps[index],
                          ),
                      ],
                    ),
                  ],
                  if (primaryLabel != null && onPrimary != null) ...[
                    SizedBox(height: 18.h),
                    Wrap(
                      spacing: 8.w,
                      runSpacing: 8.h,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF0B1220),
                          ),
                          onPressed: onPrimary,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text(primaryLabel!),
                        ),
                        if (secondaryLabel != null && onSecondary != null)
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.35),
                              ),
                            ),
                            onPressed: onSecondary,
                            child: Text(secondaryLabel!),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum NodesJourneyStepState {
  complete,
  current,
  upcoming,
}

class NodesJourneyStep {
  const NodesJourneyStep({
    required this.label,
    required this.state,
  });

  final String label;
  final NodesJourneyStepState state;
}

class _NodesJourneyStepChip extends StatelessWidget {
  const _NodesJourneyStepChip({
    required this.index,
    required this.step,
  });

  final int index;
  final NodesJourneyStep step;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusLabel = switch (step.state) {
      NodesJourneyStepState.complete => l10n.workspaceStepDone,
      NodesJourneyStepState.current => l10n.workspaceStepCurrent,
      NodesJourneyStepState.upcoming => l10n.workspaceStepUpcoming,
    };
    final color = switch (step.state) {
      NodesJourneyStepState.complete => const Color(0xFF0E9F6E),
      NodesJourneyStepState.current => const Color(0xFF1452CC),
      NodesJourneyStepState.upcoming => const Color(0xFF98A2B3),
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999.r),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24.w,
            height: 24.w,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999.r),
            ),
            child: Center(
              child: step.state == NodesJourneyStepState.complete
                  ? Icon(Icons.check, size: 14.sp, color: color)
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: color,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          SizedBox(width: 8.w),
          Text(
            step.label,
            style: TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 8.w),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 3.h),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(999.r),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 9.sp,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
