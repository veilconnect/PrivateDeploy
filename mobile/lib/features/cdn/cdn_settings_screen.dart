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
              docsUrl: _docsUrl,
            ),
            if (provider.status == CdnStatus.verified) ...[
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
    required this.docsUrl,
  });
  final CdnProvider provider;
  final bool isZh;
  final String cfTokenDashboard;
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
                  ? '在 Cloudflare 后台创建一个 API token,模板选 '
                      '"Edit Cloudflare Workers"。点下方按钮拷贝链接到剪贴板。'
                  : 'Create an API token in the Cloudflare dashboard using the '
                      '"Edit Cloudflare Workers" template. Tap below to copy '
                      'the URL.',
              actionLabel:
                  isZh ? '拷贝 Cloudflare 链接' : 'Copy Cloudflare URL',
              onAction: () =>
                  _copyToClipboard(context, cfTokenDashboard, isZh: isZh),
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
                onPressed: () => _copy(context, dep.workerHost),
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
                    child: Text(
                      dep.workerHost,
                      style: TextStyle(
                          fontSize: 11.sp,
                          fontFamily: 'monospace',
                          color: Colors.grey[800]),
                      overflow: TextOverflow.ellipsis,
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
