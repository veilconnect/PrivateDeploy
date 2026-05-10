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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CdnProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isZh = Localizations.localeOf(context).languageCode.startsWith('zh');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cdnAccelerationTitle)),
      body: Consumer2<CdnProvider, CloudProvider>(
        builder: (context, provider, cloud, _) => ListView(
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
            if (provider.status == CdnStatus.verified) ...[
              SizedBox(height: 14.h),
              _CustomDomainSection(provider: provider, isZh: isZh),
              SizedBox(height: 14.h),
              _NodesSection(
                provider: provider,
                cloud: cloud,
                isZh: isZh,
              ),
            ],
          ],
        ),
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
                style: TextStyle(
                    fontSize: 14.sp, fontWeight: FontWeight.w700),
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
            if (provider.status == CdnStatus.verified) ...[
              SizedBox(height: 12.h),
              if ((provider.accountEmail ?? '').isNotEmpty)
                _kv(isZh ? '账号' : 'Account', provider.accountEmail!),
              if ((provider.accountId ?? '').isNotEmpty)
                _kv('Account ID',
                    _truncateId(provider.accountId!)),
              if ((provider.workersSubdomain ?? '').isNotEmpty)
                _kv(
                    isZh ? 'Workers 子域' : 'Workers subdomain',
                    '${provider.workersSubdomain}.workers.dev'),
            ],
            if ((provider.lastError ?? '').isNotEmpty) ...[
              SizedBox(height: 10.h),
              Container(
                padding: EdgeInsets.all(10.w),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.4)),
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
              title: isZh ? '生成 Cloudflare API Token' : 'Create a Cloudflare API token',
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
              actionLabel: provider.status == CdnStatus.verified
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
                  ? 'Token 验证后,下方「你的节点」会列出可部署的 VPS。每个节点点一次「部署 Worker」即可——'
                      '应用会自动把脚本上传到你的 Cloudflare 账号、启用 workers.dev 子域。'
                      '⚠️ 老节点(没有 relay port)需要先重新部署一次才能用 CDN 加速。'
                  : 'After token verification, your eligible VPS nodes appear '
                      'below in "Your nodes". Tap "Deploy Worker" per node — '
                      'the app uploads the script to your Cloudflare account '
                      'and enables the workers.dev subdomain automatically. '
                      '⚠️ Older nodes (without relay port) need a re-deploy '
                      'before CDN can be used.',
              actionLabel: isZh ? '查看部署文档' : 'View deploy docs',
              onAction: () => _copyToClipboard(context, docsUrl, isZh: isZh),
            ),
            if (provider.status != CdnStatus.disabled) ...[
              SizedBox(height: 8.h),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _confirmClear(context, isZh: isZh),
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent),
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
    required String actionLabel,
    required VoidCallback onAction,
    bool busy = false,
  }) {
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
                        fontSize: 12.sp,
                        height: 1.5,
                        color: Colors.grey[700])),
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
        title: Text(isZh ? '粘贴 Cloudflare API token' : 'Paste Cloudflare API token'),
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

  Future<void> _confirmClear(BuildContext context,
      {required bool isZh}) async {
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
        : (widget.provider.lastError ??
            (isZh ? '保存失败' : 'Save failed'));
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

    return Card(
      child: Padding(
        padding: EdgeInsets.all(14.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isZh ? '自定义域名 (可选)' : 'Custom domain (optional)',
              style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 6.h),
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
                    style: TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
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
                    style: TextStyle(fontSize: 12.sp, color: Colors.grey[700]),
                  ),
                ],
              ],
            ],
          ],
        ),
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
            n.hasIp &&
            n.nodeInfo != null &&
            n.nodeInfo!.vlessUuid.isNotEmpty)
        .toList(growable: false);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(14.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isZh ? '你的节点' : 'Your nodes',
              style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700),
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
                  Text(node.label,
                      style: TextStyle(
                          fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 2.h),
                  Text(
                      hasRelay
                          ? '${node.ipv4} · relay :$relayPort'
                          : '${node.ipv4} · ' +
                              (isZh ? 'CDN 不可用(需重新部署)' : 'CDN unavailable (re-deploy)'),
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
                onPressed:
                    canDeploy ? () => _deploy(context) : null,
                child: provider.isDeploying
                    ? SizedBox(
                        width: 14.w,
                        height: 14.w,
                        child: const CircularProgressIndicator(
                            strokeWidth: 2),
                      )
                    : Text(isZh ? '部署 Worker' : 'Deploy Worker'),
              ),
          ],
        ),
        if (dep != null)
          Padding(
            padding: EdgeInsets.only(top: 6.h, left: 2.w),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 8.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: const Color(0xFF15803D).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_done_outlined,
                      size: 14.sp,
                      color: const Color(0xFF15803D)),
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
                                  : (isZh
                                      ? '正在配置中…'
                                      : 'Provisioning…'),
                          style: TextStyle(
                              fontSize: 11.sp,
                              fontFamily: 'monospace',
                              color: Colors.grey[800]),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if ((dep.customHost?.isNotEmpty ?? false) &&
                            dep.customHostStatus == 'pending')
                          Padding(
                            padding: EdgeInsets.only(top: 2.h),
                            child: Text(
                              // Probe checks the full CF→Worker→VPS path,
                              // not just cert. Phrase reflects either
                              // step still being in progress so the user
                              // knows it's not stuck on certs alone.
                              dep.workerHost.isNotEmpty
                                  ? (isZh
                                      ? '正在验证 CDN 中转链路…暂用 workers.dev'
                                      : 'Verifying CDN relay path; using workers.dev')
                                  : (isZh
                                      ? '正在验证 CDN 中转链路…'
                                      : 'Verifying CDN relay path…'),
                              style: TextStyle(
                                  fontSize: 10.sp,
                                  color: const Color(0xFFCA8A04)),
                            ),
                          ),
                        if ((dep.customHost?.isNotEmpty ?? false) &&
                            dep.customHostStatus == 'failed')
                          Padding(
                            padding: EdgeInsets.only(top: 2.h),
                            child: Text(
                              dep.workerHost.isNotEmpty
                                  ? (isZh
                                      ? 'CDN 中转链路不可用；回退 workers.dev（重新部署可重试）'
                                      : 'CDN relay path unreachable; fell back to workers.dev (redeploy to retry)')
                                  : (isZh
                                      ? 'CDN 中转链路不可用（重新部署可重试）'
                                      : 'CDN relay path unreachable (redeploy to retry)'),
                              style: TextStyle(
                                  fontSize: 10.sp,
                                  color: const Color(0xFFDC2626)),
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
            style:
                FilledButton.styleFrom(backgroundColor: Colors.redAccent),
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
        content: Text(provider.lastError ??
            (isZh ? '删除失败' : 'Delete failed')),
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
