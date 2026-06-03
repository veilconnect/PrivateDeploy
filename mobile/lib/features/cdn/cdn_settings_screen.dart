import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../cloud/cloud_models.dart';
import '../cloud/cloud_provider.dart';
import 'cdn_provider.dart';

/// Settings → CDN acceleration.
///
/// Phase 1/2 scope: token storage + verification only. Auto-deploy of the
/// relay Worker is phase 4; until then, this screen surfaces the user's
/// account info and points at the manual deploy guide
/// ([docs/cdn-acceleration/README.md]).
class CdnSettingsScreen extends StatefulWidget {
  const CdnSettingsScreen({Key? key}) : super(key: key);

  @override
  State<CdnSettingsScreen> createState() => _CdnSettingsScreenState();
}

class _CdnSettingsScreenState extends State<CdnSettingsScreen> {
  static const _cfTokenDashboard =
      'https://dash.cloudflare.com/profile/api-tokens';
  static const _docsUrl =
      'https://github.com/veilconnect/PrivateDeploy/blob/main/docs/cdn-acceleration/README.md';

  // CF dashboard supports prefilling User API token creation via
  // permissionGroupKeys + name + scope params. We use this to skip the
  // five-row permission ritual entirely — clicking opens a token form
  // with the three scopes M1 actually needs already selected.
  // Source: developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/
  //
  // accountId pre-filter: when token already verified we know the actual
  // account; passing it pins the token-creation form to that account so
  // multi-account users don't accidentally pick another's zones later.
  static String _cfTokenDeeplinkFor(String? verifiedAccountId) {
    final perms = Uri.encodeComponent(
      '[{"key":"workers_scripts","type":"edit"},'
      '{"key":"account_settings","type":"read"},'
      '{"key":"zone","type":"read"}]',
    );
    final aid = (verifiedAccountId != null && verifiedAccountId.isNotEmpty)
        ? verifiedAccountId
        : '*';
    return 'https://dash.cloudflare.com/profile/api-tokens'
        '?permissionGroupKeys=$perms'
        '&name=PrivateDeploy+CDN'
        '&accountId=$aid'
        '&zoneId=all';
  }

  final ScrollController _scrollController = ScrollController();
  // GlobalKey on the nodes section so a successful verify can scroll it
  // into view. Without this jump, the section just pops in below the
  // fold and users have no idea anything changed — leading to repeat
  // taps on Step 3 looking for a button that's now further down.
  final GlobalKey _nodesSectionKey = GlobalKey();
  CdnStatus? _previousStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CdnProvider>().load();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Fire-once scroll into "your nodes" after the very first time the
  /// provider flips into a fully-verified state. Ignored on the
  /// verifiedButIncomplete → verified transition that happens when the
  /// user binds a custom domain after token verify; that path still
  /// benefits because the section is what they're already looking at.
  void _maybeScrollToNodesSection(CdnStatus current) {
    final wasReady = _previousStatus == CdnStatus.verified;
    _previousStatus = current;
    if (current != CdnStatus.verified || wasReady) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _nodesSectionKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isZh = Localizations.localeOf(context).languageCode.startsWith('zh');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cdnAccelerationTitle)),
      body: Consumer2<CdnProvider, CloudProvider>(
        builder: (context, provider, cloud, _) {
          _maybeScrollToNodesSection(provider.status);
          return ListView(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(16.w, 16.h, 16.w, 24.h),
            children: [
              _IntroCard(isZh: isZh),
              SizedBox(height: 14.h),
              _StatusCard(provider: provider, isZh: isZh),
              SizedBox(height: 14.h),
              _SetupSection(
                provider: provider,
                isZh: isZh,
                cfTokenDashboard: _cfTokenDashboard,
                cfTokenDeeplink: _cfTokenDeeplinkFor(provider.accountId),
                docsUrl: _docsUrl,
              ),
              // verifiedButIncomplete still shows the custom-domain section
              // because binding a domain is one of the two ways to clear
              // that state (the other being claiming a workers.dev
              // subdomain in the Cloudflare dashboard). Nodes section is
              // hidden until deploy can actually succeed — listing them
              // with a disabled "Deploy" button just confuses the user.
              if (provider.status == CdnStatus.verified ||
                  provider.status == CdnStatus.verifiedButIncomplete) ...[
                SizedBox(height: 14.h),
                _CustomDomainSection(provider: provider, isZh: isZh),
              ],
              if (provider.status == CdnStatus.verified) ...[
                SizedBox(height: 14.h),
                KeyedSubtree(
                  key: _nodesSectionKey,
                  child: _NodesSection(
                    provider: provider,
                    cloud: cloud,
                    isZh: isZh,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.isZh});
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF1452CC);
    return Container(
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(14.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 20.sp, color: accent),
              SizedBox(width: 8.w),
              Text(
                isZh ? '什么是 CDN 加速?' : 'What is CDN acceleration?',
                style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            isZh
                ? '当你的手机数据网络长期出现"上游不可达"时,可以让客户端通过 '
                    'Cloudflare 边缘 IP 中转到你的 VPS——蜂窝运营商不会屏蔽 Cloudflare 段。\n\n'
                    '需要一个免费的 Cloudflare 账号。流量仍然端到端加密,'
                    'Cloudflare 只看到加密字节,看不到你的 VLESS UUID 或访问内容。'
                : 'When cellular keeps showing "upstream unreachable", you can '
                    'route your client through Cloudflare edge IPs to reach your '
                    'VPS — carriers do not filter Cloudflare ranges.\n\n'
                    'Requires a free Cloudflare account. Traffic stays end-to-end '
                    'encrypted; Cloudflare sees only encrypted bytes — never your '
                    'VLESS UUID or your traffic content.',
            style: TextStyle(
                fontSize: 13.sp, height: 1.5, color: Colors.grey[800]),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.provider, required this.isZh});
  final CdnProvider provider;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (provider.status) {
      CdnStatus.disabled => (
          isZh ? '未配置' : 'Not configured',
          const Color(0xFF6B7280),
        ),
      CdnStatus.unverified => (
          isZh ? '已保存,未验证' : 'Saved, not verified',
          const Color(0xFFB45309),
        ),
      // Distinct yellow state — token is good but deploy will fail
      // until either workers.dev subdomain or a custom domain is in
      // place. We previously rendered this as plain green "Verified"
      // with a buried orange warning, which let users tap Deploy and
      // hit a hard error.
      CdnStatus.verifiedButIncomplete => (
          isZh ? '已验证 · 待完成' : 'Verified · setup incomplete',
          const Color(0xFFCA8A04),
        ),
      CdnStatus.verified => (
          isZh ? '已验证' : 'Verified',
          const Color(0xFF15803D),
        ),
    };
    return Card(
      child: Padding(
        padding: EdgeInsets.all(14.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10.w,
                  height: 10.w,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 8.w),
                Text(label,
                    style: TextStyle(
                        fontSize: 14.sp, fontWeight: FontWeight.w700)),
              ],
            ),
            // Account details are useful in both verified and the
            // verifiedButIncomplete in-progress state — they confirm
            // *which* account the token is bound to. Showing them only
            // when fully verified hides the "you're connected to
            // account X but it's missing a subdomain" narrative that
            // the warning text below needs as context.
            if (provider.status == CdnStatus.verified ||
                provider.status == CdnStatus.verifiedButIncomplete) ...[
              SizedBox(height: 12.h),
              if ((provider.accountEmail ?? '').isNotEmpty)
                _kv(isZh ? '账号' : 'Account', provider.accountEmail!),
              if ((provider.accountId ?? '').isNotEmpty)
                _kv('Account ID', _truncateId(provider.accountId!)),
              if ((provider.workersSubdomain ?? '').isNotEmpty)
                _kv(isZh ? 'Workers 子域' : 'Workers subdomain',
                    '${provider.workersSubdomain}.workers.dev'),
            ],
            if ((provider.lastError ?? '').isNotEmpty) ...[
              SizedBox(height: 10.h),
              Container(
                padding: EdgeInsets.all(10.w),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  border:
                      Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text(
                  provider.lastError!,
                  style: TextStyle(fontSize: 12.sp, color: Colors.grey[800]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: EdgeInsets.only(top: 4.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90.w,
            child: Text(k,
                style: TextStyle(fontSize: 12.sp, color: Colors.grey[600])),
          ),
          Expanded(
            child: Text(v,
                style: TextStyle(fontSize: 12.sp, color: Colors.grey[900])),
          ),
        ],
      ),
    );
  }

  String _truncateId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 6)}';
  }
}

class _SetupSection extends StatelessWidget {
  const _SetupSection({
    required this.provider,
    required this.isZh,
    required this.cfTokenDashboard,
    required this.cfTokenDeeplink,
    required this.docsUrl,
  });
  final CdnProvider provider;
  final bool isZh;
  final String cfTokenDashboard;
  final String cfTokenDeeplink;
  final String docsUrl;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(14.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isZh ? '设置步骤' : 'How to set up',
              style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8.h),
            _step(
              context,
              n: 1,
              title: isZh
                  ? '生成 Cloudflare API Token'
                  : 'Create a Cloudflare API token',
              body: isZh
                  ? '点下方按钮拷贝链接,在浏览器打开 — Cloudflare 会预填好我们需要的 '
                      '3 行权限 (Workers Scripts:Edit / Account Settings:Read / '
                      'Zone:Read),点 Continue → Create Token,然后把 Token 拷回 '
                      'Step 2。'
                  : 'Tap below to copy the prefilled URL — Cloudflare will '
                      'pre-select the three permissions PrivateDeploy needs '
                      '(Workers Scripts:Edit / Account Settings:Read / '
                      'Zone:Read). Hit Continue → Create Token in Cloudflare, '
                      'then paste the token into Step 2.',
              actionLabel:
                  isZh ? '拷贝预填链接 (推荐)' : 'Copy prefilled URL (recommended)',
              onAction: () =>
                  _copyToClipboard(context, cfTokenDeeplink, isZh: isZh),
            ),
            _step(
              context,
              n: 2,
              title: isZh ? '粘贴 token 并验证' : 'Paste token & verify',
              body: isZh
                  ? '把刚才生成的 token 粘贴到这里,我们会调用 CF API 验证它是否有效,'
                      '同时获取你的账号信息和 workers.dev 子域。Token 用 '
                      '加密存储保存在本机,不会上传到任何服务器。'
                  : 'Paste the token here. We call the CF API to confirm it '
                      'works and to fetch your account and workers.dev '
                      'subdomain. The token is stored in this device\'s '
                      'encrypted storage; it never leaves your phone.',
              actionLabel: (provider.status == CdnStatus.verified ||
                      provider.status == CdnStatus.verifiedButIncomplete)
                  ? (isZh ? '重新验证 / 更换 token' : 'Re-verify / change token')
                  : (isZh ? '粘贴 token' : 'Paste token'),
              onAction: () => _showTokenDialog(context, isZh: isZh),
              busy: provider.isVerifying,
            ),
            _step(
              context,
              n: 3,
              title: isZh ? '部署 Relay Worker' : 'Deploy the relay Worker',
              body: isZh
                  ? 'Token 验证后，下方「你的节点」会列出可部署的 VPS。每个节点点一次「部署 Worker」按钮即可——'
                      '应用会自动把脚本上传到你的 Cloudflare 账号、启用 workers.dev 子域。'
                      '⚠️ 老节点(没有 relay port)需要先重新部署一次 VPS 才能用 CDN 加速。'
                  : 'After token verification, your eligible VPS nodes appear '
                      'below in "Your nodes". Tap "Deploy Worker" per node — '
                      'the app uploads the script to your Cloudflare account '
                      'and enables the workers.dev subdomain automatically. '
                      '⚠️ Older nodes (without relay port) need a VPS '
                      're-deploy before CDN can be used.',
              // Step 3 is satisfied by tapping a per-node "Deploy" button
              // further down — no top-level action needed. Earlier copy
              // here was "View deploy docs" which contradicted the body
              // and confused first-run users into thinking the docs were
              // the primary path.
              actionLabel: null,
              onAction: null,
            ),
            if (provider.status != CdnStatus.disabled) ...[
              SizedBox(height: 8.h),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _confirmClear(context, isZh: isZh),
                  icon:
                      const Icon(Icons.delete_outline, color: Colors.redAccent),
                  label: Text(
                    isZh ? '移除已保存的 token' : 'Remove saved token',
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _step(
    BuildContext context, {
    required int n,
    required String title,
    required String body,
    String? actionLabel,
    VoidCallback? onAction,
    bool busy = false,
  }) {
    final hasAction = actionLabel != null && onAction != null;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 10.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24.w,
            height: 24.w,
            margin: EdgeInsets.only(top: 2.h),
            decoration: BoxDecoration(
              color: const Color(0xFF1452CC),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text('$n',
                style: TextStyle(
                    fontSize: 12.sp,
                    color: Colors.white,
                    fontWeight: FontWeight.w700)),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13.sp, fontWeight: FontWeight.w700)),
                SizedBox(height: 4.h),
                Text(body,
                    style: TextStyle(
                        fontSize: 12.sp, height: 1.5, color: Colors.grey[700])),
                if (hasAction) ...[
                  SizedBox(height: 8.h),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: busy ? null : onAction,
                      child: busy
                          ? SizedBox(
                              width: 14.w,
                              height: 14.w,
                              child: const CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : Text(actionLabel),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(
    BuildContext context,
    String url, {
    required bool isZh,
  }) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isZh ? '已复制到剪贴板' : 'Copied to clipboard'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _showTokenDialog(BuildContext context,
      {required bool isZh}) async {
    final controller = TextEditingController();
    final newToken = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(
            isZh ? '粘贴 Cloudflare API token' : 'Paste Cloudflare API token'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          maxLines: 1,
          decoration: InputDecoration(
            hintText: isZh ? 'Bearer ...' : 'Bearer ...',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(isZh ? '验证' : 'Verify'),
          ),
        ],
      ),
    );
    if (newToken == null || newToken.isEmpty || !context.mounted) return;
    final provider = context.read<CdnProvider>();
    final ok = await provider.verifyAndPersist(newToken);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (isZh ? '验证成功' : 'Token verified')
          : (provider.lastError ?? (isZh ? '验证失败' : 'Verification failed'))),
    ));
  }

  Future<void> _confirmClear(BuildContext context, {required bool isZh}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isZh ? '移除 token?' : 'Remove token?'),
        content: Text(isZh
            ? '会同时清除已保存的账号信息。可以稍后重新粘贴。'
            : 'This also clears saved account info. You can paste a token again later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(isZh ? '移除' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<CdnProvider>().clear();
  }
}

/// M1 — Workers Custom Domain binding section. Visible only when the
/// token is verified. Lazy-loads zones the first time the toggle is
/// flipped on (many users have Workers-only tokens with zero zones, so
/// don't fetch on mount).
class _CustomDomainSection extends StatefulWidget {
  const _CustomDomainSection({required this.provider, required this.isZh});
  final CdnProvider provider;
  final bool isZh;

  @override
  State<_CustomDomainSection> createState() => _CustomDomainSectionState();
}

class _CustomDomainSectionState extends State<_CustomDomainSection> {
  bool _enabled = false;
  String? _zoneId;
  late final TextEditingController _subdomainCtl;

  @override
  void initState() {
    super.initState();
    _subdomainCtl = TextEditingController(text: 'relay');
    final cd = widget.provider.customDomain;
    if (cd != null) {
      _enabled = true;
      _zoneId = cd.zoneId;
      _subdomainCtl.text = cd.subdomain;
      // The toggle came up pre-enabled because we loaded a saved binding
      // from disk. Eagerly fetch zones so the dropdown isn't stuck on
      // "no zones" until the user toggles off+on. Skip when a fresh
      // listZones is already cached from this session.
      if (widget.provider.zones.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.provider.listZones();
        });
      }
    }
  }

  @override
  void didUpdateWidget(_CustomDomainSection old) {
    super.didUpdateWidget(old);
    final cd = widget.provider.customDomain;
    if (cd != null && _zoneId != cd.zoneId) {
      _zoneId = cd.zoneId;
      _subdomainCtl.text = cd.subdomain;
      _enabled = true;
    }
  }

  @override
  void dispose() {
    _subdomainCtl.dispose();
    super.dispose();
  }

  Future<void> _onToggle(bool next) async {
    setState(() => _enabled = next);
    if (next && widget.provider.zones.isEmpty) {
      await widget.provider.listZones();
    }
  }

  Future<void> _onSave() async {
    final zid = _zoneId;
    final sub = _subdomainCtl.text.trim();
    if (zid == null || zid.isEmpty || sub.isEmpty) return;
    final ok = await widget.provider.setCustomDomain(zid, sub);
    if (!mounted) return;
    final isZh = widget.isZh;
    final msg = ok
        ? (isZh ? '已保存自定义域名绑定' : 'Custom domain saved')
        : (widget.provider.lastError ?? (isZh ? '保存失败' : 'Save failed'));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _onClear() async {
    await widget.provider.clearCustomDomain();
    if (!mounted) return;
    setState(() => _enabled = false);
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final p = widget.provider;
    final zones = p.zones;
    final loading = p.isZonesLoading;
    final saving = p.isSavingCustomDomain;

    final previewHost = (() {
      final sub = _subdomainCtl.text.trim();
      if (sub.isEmpty) return '';
      final zone = zones.firstWhere(
        (z) => z.id == _zoneId,
        orElse: () => CdnZone(id: '', name: ''),
      );
      if (zone.id.isEmpty) return '';
      return '$sub-<node>.${zone.name}';
    })();

    // Collapsed-by-default ExpansionTile. The full custom-domain
    // editor used to be a ~200px always-visible card pushing the main
    // "Your nodes" list below the fold, even though most users never
    // touch this section in their lifetime. As a one-line collapsed
    // tile with a status summary it stays discoverable for the users
    // who do need it, without blocking the primary flow for the
    // majority who don't.
    final bound = p.customDomain;
    final headerSubtitle = bound == null
        ? (isZh
            ? '可选 · 用 Cloudflare 上的域名替代 workers.dev'
            : 'Optional · replace workers.dev with a domain on Cloudflare')
        : (isZh ? '已绑定: ${bound.hostPattern}' : 'Bound: ${bound.hostPattern}');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: bound != null,
        tilePadding: EdgeInsets.symmetric(horizontal: 14.w),
        childrenPadding: EdgeInsets.fromLTRB(14.w, 0, 14.w, 14.w),
        title: Text(
          isZh ? '自定义域名 (可选)' : 'Custom domain (optional)',
          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: EdgeInsets.only(top: 2.h),
          child: Text(
            headerSubtitle,
            style: TextStyle(
              fontSize: 11.sp,
              color: Colors.grey[700],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isZh
                    ? '把 Worker 同时绑定到你 Cloudflare 上的某个域名 (例如 '
                        'relay-<node>.example.com)。部分蜂窝运营商会针对 '
                        '*.workers.dev 做指纹/投毒,自定义域名能绕开。'
                    : 'Bind the Worker to a domain on your Cloudflare zone '
                        '(e.g. relay-<node>.example.com). Some carriers '
                        'fingerprint or DNS-poison *.workers.dev; a personal '
                        'domain bypasses that.',
                style: TextStyle(
                    fontSize: 12.sp, height: 1.5, color: Colors.grey[700]),
              ),
              SizedBox(height: 8.h),
              // SwitchListTile makes the entire row a tap target — bare
              // Switch widgets have a small hit area that's annoying on
              // touchscreens (and effectively un-driveable from `adb input
              // tap`, which is also how tap automation breaks accidentally).
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _enabled,
                onChanged: _onToggle,
                title: Text(
                  isZh ? '启用自定义域名' : 'Use custom domain',
                  style: TextStyle(fontSize: 13.sp),
                ),
              ),
              if (_enabled) ...[
                SizedBox(height: 8.h),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (zones.isEmpty)
                  Text(
                    isZh
                        ? '当前 token 看不到任何活跃的 zone。请先在 Cloudflare 添加站点,'
                            '并确认 token 拥有该 zone 的 Zone:Read 权限。'
                        : 'No active zones visible to this token. Add a site to '
                            'Cloudflare first and make sure your token has '
                            'Zone:Read for it.',
                    style: TextStyle(
                        fontSize: 12.sp, color: const Color(0xFFB05010)),
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _zoneId,
                    decoration: InputDecoration(
                      labelText: isZh ? '选择域名' : 'Zone',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: zones
                        .map((z) => DropdownMenuItem(
                              value: z.id,
                              child: Text(z.name),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _zoneId = v),
                  ),
                  SizedBox(height: 8.h),
                  TextField(
                    controller: _subdomainCtl,
                    decoration: InputDecoration(
                      labelText: isZh ? '子域名前缀' : 'Subdomain prefix',
                      helperText: isZh
                          ? '不含 ".",最终主机 = 前缀-<节点哈希>.根域名'
                          : 'No "."; final host = prefix-<node-hash>.zone',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  SizedBox(height: 6.h),
                  if (previewHost.isNotEmpty)
                    Text(
                      (isZh ? '生效后域名: ' : 'Resulting host: ') + previewHost,
                      style:
                          TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
                    ),
                  SizedBox(height: 10.h),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: saving
                            ? null
                            : (_zoneId == null ||
                                    _subdomainCtl.text.trim().isEmpty
                                ? null
                                : _onSave),
                        child: Text(saving
                            ? (isZh ? '保存中…' : 'Saving…')
                            : (isZh ? '保存绑定' : 'Save binding')),
                      ),
                      SizedBox(width: 8.w),
                      if (p.customDomain != null)
                        TextButton(
                          onPressed: saving ? null : _onClear,
                          child: Text(isZh ? '关闭并解绑' : 'Disable and unbind'),
                        ),
                    ],
                  ),
                  if (p.customDomain != null) ...[
                    SizedBox(height: 6.h),
                    Text(
                      (isZh ? '已绑定: ' : 'Bound: ') +
                          p.customDomain!.hostPattern,
                      style:
                          TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// "你的节点"区块:列出所有云节点,逐个显示部署/删除 Worker 的 UI。
/// 只在 token 已验证后显示。
class _NodesSection extends StatelessWidget {
  const _NodesSection({
    required this.provider,
    required this.cloud,
    required this.isZh,
  });
  final CdnProvider provider;
  final CloudProvider cloud;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final nodes = cloud.instances
        .where((n) =>
            n.hasIp && n.nodeInfo != null && n.nodeInfo!.vlessUuid.isNotEmpty)
        .toList(growable: false);

    final hasUnrecoverable =
        nodes.any((n) => (n.nodeInfo?.vlessRelayPort ?? 0) <= 0);
    return Card(
      child: Padding(
        padding: EdgeInsets.all(14.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isZh ? '你的节点' : 'Your nodes',
                    style:
                        TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: isZh ? '刷新节点列表' : 'Refresh nodes',
                  icon: Icon(Icons.refresh,
                      size: 20.w,
                      color: hasUnrecoverable ? Colors.orange : null),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    await cloud.loadInstances();
                    messenger?.showSnackBar(SnackBar(
                      content: Text(isZh ? '节点列表已刷新' : 'Nodes refreshed'),
                      duration: const Duration(seconds: 2),
                    ));
                  },
                ),
              ],
            ),
            SizedBox(height: 4.h),
            Text(
              isZh
                  ? '为每个节点部署一个 Cloudflare Worker;Worker URL 即 CDN 入口。'
                  : 'Deploy one Cloudflare Worker per node — the Worker URL is '
                      'your CDN entry point.',
              style: TextStyle(
                  fontSize: 12.sp, color: Colors.grey[700], height: 1.4),
            ),
            SizedBox(height: 10.h),
            if (nodes.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12.h),
                child: Text(
                  isZh
                      ? '暂无可部署的节点。先在「云线路」里部署一台 VPS。'
                      : 'No deployable nodes. Deploy a VPS in the cloud list first.',
                  style: TextStyle(fontSize: 12.sp, color: Colors.grey[600]),
                ),
              ),
            for (final node in nodes) ...[
              const Divider(height: 18),
              _NodeRow(
                provider: provider,
                node: node,
                isZh: isZh,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.provider,
    required this.node,
    required this.isZh,
  });
  final CdnProvider provider;
  final CloudInstance node;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final dep = provider.deploymentFor(node.id);
    final relayPort = node.nodeInfo!.vlessRelayPort;
    final hasRelay = relayPort > 0;
    final canDeploy = provider.status == CdnStatus.verified &&
        !provider.isDeploying &&
        hasRelay;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(node.label,
                            style: TextStyle(
                                fontSize: 13.sp, fontWeight: FontWeight.w600)),
                      ),
                      // Provenance chip — only shown when a deployment
                      // exists. Lets the user instantly tell apart "I
                      // pressed Deploy myself" from "the app deployed
                      // this in the background while I was on cellular".
                      // Without this, users would re-deploy nodes the
                      // app had already provisioned via Gate ① during
                      // the previous session.
                      if (dep != null) ...[
                        SizedBox(width: 6.w),
                        _DeployProvenanceChip(dep: dep, isZh: isZh),
                      ],
                    ],
                  ),
                  SizedBox(height: 2.h),
                  Text(
                      hasRelay
                          ? '${node.ipv4} · relay :$relayPort'
                          : '${node.ipv4} · ' +
                              (isZh
                                  ? 'CDN 不可用(需重新部署)'
                                  : 'CDN unavailable (re-deploy)'),
                      style: TextStyle(
                          fontSize: 11.sp,
                          color: hasRelay ? Colors.grey[600] : Colors.orange,
                          fontFamily: 'monospace')),
                ],
              ),
            ),
            if (dep != null) ...[
              IconButton(
                tooltip: isZh ? '复制 Worker URL' : 'Copy Worker URL',
                icon: const Icon(Icons.copy, size: 18),
                // Copy the host the client would actually route through:
                // customHost only when readiness probe has confirmed it,
                // otherwise workers.dev. Stops users from sharing a
                // pending/failed cert URL.
                onPressed: () => _copy(
                  context,
                  dep.customHostReady ? dep.customHost! : dep.workerHost,
                ),
              ),
              IconButton(
                tooltip: isZh ? '删除' : 'Delete',
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 18),
                onPressed: () => _confirmDelete(context),
              ),
            ] else
              FilledButton(
                onPressed: canDeploy ? () => _deploy(context) : null,
                child: provider.isDeploying
                    ? SizedBox(
                        width: 14.w,
                        height: 14.w,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(isZh ? '部署 Worker' : 'Deploy Worker'),
              ),
          ],
        ),
        if (dep != null)
          Padding(
            padding: EdgeInsets.only(top: 6.h, left: 2.w),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: const Color(0xFF15803D).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_done_outlined,
                      size: 14.sp, color: const Color(0xFF15803D)),
                  SizedBox(width: 6.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // Always show the routable host (gated on
                          // readiness) so the inline label and the copy
                          // button agree. Empty when neither customHost
                          // is active nor a workers.dev fallback exists
                          // — the status row below explains why.
                          dep.customHostReady
                              ? dep.customHost!
                              : dep.workerHost.isNotEmpty
                                  ? dep.workerHost
                                  : (isZh ? '正在配置中…' : 'Provisioning…'),
                          style: TextStyle(
                              fontSize: 11.sp,
                              fontFamily: 'monospace',
                              color: Colors.grey[800]),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if ((dep.customHost?.isNotEmpty ?? false) &&
                            (dep.customHostStatus == 'pending' ||
                                dep.customHostStatus == 'failed'))
                          Padding(
                            padding: EdgeInsets.only(top: 2.h),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    // Probe verdict + status — same
                                    // semantics as before, just split
                                    // out so a per-row retry button
                                    // can live next to it without
                                    // forcing another redeploy round
                                    // trip when CF was simply still
                                    // propagating on the first try.
                                    _customHostStatusLabel(
                                      dep: dep,
                                      isZh: isZh,
                                      lastStatus:
                                          provider.lastProbeStatusFor(node.id),
                                    ),
                                    style: TextStyle(
                                      fontSize: 10.sp,
                                      color: dep.customHostStatus == 'failed'
                                          ? const Color(0xFFDC2626)
                                          : const Color(0xFFCA8A04),
                                    ),
                                  ),
                                ),
                                SizedBox(width: 4.w),
                                // A backend (VPS relay) 502/504 can't be fixed
                                // by repairing the Worker — hide the repair
                                // button so the label's "redeploy the node"
                                // guidance is the only action shown.
                                if (!(dep.customHostStatus == 'failed' &&
                                    const [502, 504].contains(
                                        provider.lastProbeStatusFor(node.id))))
                                  _RetryProbeButton(
                                    provider: provider,
                                    nodeId: node.id,
                                    isZh: isZh,
                                  ),
                              ],
                            ),
                          ),
                        // No workers.dev sibling in the urltest pool — a
                        // single point of failure if the custom host stalls.
                        if (provider.deploymentLacksFallback(node.id))
                          Padding(
                            padding: EdgeInsets.only(top: 2.h),
                            child: Text(
                              isZh
                                  ? '⚠ 无 workers.dev 兜底线路，建议认领子域'
                                  : '⚠ No workers.dev fallback — claim a subdomain',
                              style: TextStyle(
                                fontSize: 10.sp,
                                color: const Color(0xFFCA8A04),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _deploy(BuildContext context) async {
    final ok = await provider.deployWorkerForNode(
      nodeId: node.id,
      nodeLabel: node.label,
      backendHost: node.ipv4!,
      backendPort: node.nodeInfo!.vlessRelayPort,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (isZh ? 'Worker 已部署' : 'Worker deployed')
          : (provider.lastError ?? (isZh ? '部署失败' : 'Deploy failed'))),
    ));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isZh ? '删除该节点的 Worker?' : 'Delete this node\'s Worker?'),
        content: Text(isZh
            ? '会从你的 Cloudflare 账号上删除该 Worker。'
            : 'This will remove the Worker from your Cloudflare account.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final success = await provider.deleteWorkerForNode(node.id);
    if (!context.mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(provider.lastError ?? (isZh ? '删除失败' : 'Delete failed')),
      ));
    }
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isZh ? '已复制' : 'Copied'),
      duration: const Duration(seconds: 1),
    ));
  }
}

/// Compact chip rendering the deploy provenance + age. Shown next to the
/// node label whenever a CdnDeployment exists for that node, so users
/// can answer "wait, did I deploy this?" without expanding anything.
///
///   - auto + recent  → orange "自动 · 5 分钟前" (CF API was just touched)
///   - manual + any   → grey  "已部署 · 3 天前"  (user did this themselves)
///   - null (legacy)  → grey  "已部署 · 3 天前"  (predates the field)
///
/// Provenance string is the only signal that flips colour — age is
/// always grey to avoid screaming "this is a problem" at routine
/// deployments.
class _DeployProvenanceChip extends StatelessWidget {
  const _DeployProvenanceChip({required this.dep, required this.isZh});
  final CdnDeployment dep;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final isAuto = dep.deployedBy == 'auto';
    final label = isAuto ? (isZh ? '自动' : 'Auto') : (isZh ? '已部署' : 'Deployed');
    final age = _relativeTime(dep.deployedAt, isZh: isZh);
    final accent = isAuto ? const Color(0xFFCA8A04) : Colors.grey[600]!;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label · $age',
        style: TextStyle(
          fontSize: 10.sp,
          color: accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static String _relativeTime(DateTime t, {required bool isZh}) {
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inMinutes < 1) return isZh ? '刚刚' : 'just now';
    if (diff.inHours < 1) {
      final m = diff.inMinutes;
      return isZh ? '$m 分钟前' : '${m}m ago';
    }
    if (diff.inDays < 1) {
      final h = diff.inHours;
      return isZh ? '$h 小时前' : '${h}h ago';
    }
    final d = diff.inDays;
    return isZh ? '$d 天前' : '${d}d ago';
  }
}

/// Pick the explanatory line shown next to the customHost status. Kept
/// outside the build tree so the row layout stays readable.
String _customHostStatusLabel({
  required CdnDeployment dep,
  required bool isZh,
  int? lastStatus,
}) {
  // The text used to say "暂用 workers.dev" / "fell back to workers.dev",
  // implying the active outbound was workers.dev only. That was untrue:
  // the routing layer at main.dart's CdnEndpointResolver already prefers
  // customHost regardless of probe status, and since the side-by-side
  // change (cloud_node_config_builder: emit both hostnames into the
  // urltest pool) sing-box has BOTH paths concurrently and picks whichever
  // the carrier lets through. Talking about a "fallback" implies a
  // sequential decision that no longer exists — sing-box's urltest test
  // runs them in parallel.
  switch (dep.customHostStatus) {
    case 'pending':
      return isZh ? '正在验证 CDN 中转链路' : 'Verifying CDN relay path';
    case 'failed':
      // 502/504 = the Worker is healthy but its VPS relay backend is
      // unreachable (bad gateway). Repairing the Worker won't help — the
      // node's relay is down — so steer the user to redeploy the node.
      if (lastStatus == 502 || lastStatus == 504) {
        return isZh
            ? 'Worker 正常，但中继后端不可达 — 请重新部署该节点'
            : "Worker is up but its relay backend is down — redeploy this node";
      }
      return isZh
          ? 'CDN 探测未通过（仍会尝试连接）'
          : "CDN probe didn't pass (we'll still try)";
    default:
      return '';
  }
}

/// Compact button next to the pending/failed status row that REPAIRS a
/// stuck custom-domain deployment: it re-uploads the Worker script (from
/// the deployment's stored backend + path-secret), wires in a workers.dev
/// fallback when one is now available, and re-attaches the Workers Custom
/// Domain before re-probing. A bare probe retry can clear a slow cert but
/// can't recover an orphaned / never-activated binding (the permanent-522
/// case) — re-attaching can, which is why this drives
/// [CdnProvider.repairCustomHostForNode] rather than the probe alone.
class _RetryProbeButton extends StatefulWidget {
  const _RetryProbeButton({
    required this.provider,
    required this.nodeId,
    required this.isZh,
  });

  final CdnProvider provider;
  final String nodeId;
  final bool isZh;

  @override
  State<_RetryProbeButton> createState() => _RetryProbeButtonState();
}

class _RetryProbeButtonState extends State<_RetryProbeButton> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    if (_running) {
      return SizedBox(
        width: 18.w,
        height: 18.w,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return InkWell(
      onTap: () => _retry(context),
      borderRadius: BorderRadius.circular(4.r),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
        child: Text(
          widget.isZh ? '修复并重试' : 'Repair & retry',
          style: TextStyle(
            fontSize: 10.sp,
            color: const Color(0xFF1452CC),
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Future<void> _retry(BuildContext context) async {
    setState(() => _running = true);
    final ok = await widget.provider.repairCustomHostForNode(widget.nodeId);
    if (!mounted) return;
    setState(() => _running = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        ok
            ? (widget.isZh
                ? 'CDN 已重新部署，正在后台验证链路'
                : 'CDN redeployed — verifying the relay path in the background')
            : (widget.isZh
                ? 'CDN 修复失败，稍后可再试'
                : 'CDN repair failed; you can try again'),
      ),
      duration: const Duration(seconds: 3),
    ));
  }
}
