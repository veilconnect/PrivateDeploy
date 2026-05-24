import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cdn/cdn_provider.dart';
import '../cdn/cdn_settings_screen.dart';

/// Top-level settings entry for CDN acceleration. Without this card the
/// CDN feature was only reachable via the failure banner on the nodes
/// screen — i.e. you had to *already be failing to connect* before the
/// app would show you how to set it up. This card surfaces it as a
/// regular always-discoverable settings item, badged with the current
/// state so users notice things like "verified but no subdomain bound"
/// without having to drill in.
class SettingsCdnSection extends StatelessWidget {
  const SettingsCdnSection({Key? key}) : super(key: key);

  void _open(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const CdnSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CdnProvider>(
      builder: (context, cdn, _) {
        final l10n = AppLocalizations.of(context)!;
        final isZh =
            Localizations.localeOf(context).languageCode.startsWith('zh');
        final (statusText, statusColor) = _renderStatus(
          status: cdn.status,
          deploymentCount: cdn.deployments.length,
          isZh: isZh,
        );
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color:
                  Theme.of(context).dividerColor.withValues(alpha: 0.12),
            ),
          ),
          child: ListTile(
            contentPadding:
                EdgeInsets.symmetric(horizontal: 16.w, vertical: 4.h),
            leading: Icon(
              Icons.bolt_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(l10n.cdnAccelerationTitle),
            subtitle: Padding(
              padding: EdgeInsets.only(top: 4.h),
              child: Row(
                children: [
                  Container(
                    width: 8.w,
                    height: 8.w,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 6.w),
                  Flexible(
                    child: Text(
                      statusText,
                      style: TextStyle(fontSize: 12.sp),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(context),
          ),
        );
      },
    );
  }

  static (String, Color) _renderStatus({
    required CdnStatus status,
    required int deploymentCount,
    required bool isZh,
  }) {
    switch (status) {
      case CdnStatus.disabled:
        return (
          isZh ? '未配置 · 点此启用' : 'Not configured · tap to set up',
          const Color(0xFF6B7280),
        );
      case CdnStatus.unverified:
        return (
          isZh ? '已保存，未验证' : 'Saved, not verified',
          const Color(0xFFB45309),
        );
      case CdnStatus.verifiedButIncomplete:
        return (
          isZh
              ? '已验证 · 尚未声明子域'
              : 'Verified · subdomain not claimed',
          const Color(0xFFCA8A04),
        );
      case CdnStatus.verified:
        if (deploymentCount == 0) {
          return (
            isZh ? '已验证 · 暂无部署' : 'Verified · no Workers deployed',
            const Color(0xFF15803D),
          );
        }
        return (
          isZh
              ? '已部署 $deploymentCount 个 Worker'
              : '$deploymentCount Worker${deploymentCount == 1 ? '' : 's'} deployed',
          const Color(0xFF15803D),
        );
    }
  }
}
