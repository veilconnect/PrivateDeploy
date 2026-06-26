import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../l10n/app_localizations.dart';

/// User-facing explainer that opens from the orange UpstreamDegraded banner.
/// The full prose lives in this file as two locale variants so we don't
/// explode the .arb files with tens of long-form strings — a translator
/// looking to add a new locale only needs to copy [_zhContent]/[_enContent]
/// and wire it into [_helpContent].
class CellularHelpScreen extends StatelessWidget {
  const CellularHelpScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isZh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final c = isZh ? _zhContent : _enContent;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cellularHelpTitle),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 24.h),
        children: [
          _Callout(
            text: c.tldr,
            icon: Icons.info_outline,
            color: const Color(0xFF1452CC),
          ),
          SizedBox(height: 18.h),
          for (final section in c.sections) ...[
            _SectionHeading(text: section.title),
            SizedBox(height: 6.h),
            for (final block in section.blocks) ...[
              block.build(context),
              SizedBox(height: 8.h),
            ],
            SizedBox(height: 14.h),
          ],
          SizedBox(height: 8.h),
          _Callout(
            text: c.disclaimer,
            icon: Icons.lightbulb_outline,
            color: const Color(0xFF7C3AED),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 6.h, bottom: 4.h),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 16.sp,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.text, required this.icon, required this.color});
  final String text;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(14.r),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20.sp, color: color),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.sp,
                height: 1.5,
                color: Colors.grey[800],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

abstract class _Block {
  Widget build(BuildContext context);
}

class _Para extends _Block {
  _Para(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 13.sp, height: 1.55, color: Colors.grey[800]),
    );
  }
}

class _Bullet extends _Block {
  _Bullet(this.text, {this.bold = false});
  final String text;
  final bool bold;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 4.w, top: 2.h, bottom: 2.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 6.h, right: 8.w),
            child: Container(
              width: 5.w,
              height: 5.w,
              decoration: BoxDecoration(
                color: Colors.grey[700],
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.sp,
                height: 1.55,
                color: Colors.grey[800],
                fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-column comparison row (target/result) used in the test-data tables.
class _CompareTable extends _Block {
  _CompareTable({required this.headers, required this.rows});
  final (String, String) headers;
  final List<(String, String, bool ok)> rows;
  @override
  Widget build(BuildContext context) {
    final cellPad = EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(10.r),
      ),
      child: Column(
        children: [
          // Header
          Container(
            decoration: BoxDecoration(color: Colors.grey[100]),
            padding: cellPad,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(headers.$1,
                      style: TextStyle(
                          fontSize: 12.sp, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  flex: 4,
                  child: Text(headers.$2,
                      style: TextStyle(
                          fontSize: 12.sp, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            Container(
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(
                        top: BorderSide(color: Colors.grey[200]!, width: 1),
                      ),
              ),
              padding: cellPad,
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Text(rows[i].$1,
                        style: TextStyle(
                            fontSize: 12.sp,
                            fontFamily: 'monospace',
                            color: Colors.grey[900])),
                  ),
                  Expanded(
                    flex: 4,
                    child: Row(
                      children: [
                        Icon(
                          rows[i].$3 ? Icons.check_circle : Icons.cancel,
                          color: rows[i].$3
                              ? const Color(0xFF22A06B)
                              : const Color(0xFFE54D2E),
                          size: 14.sp,
                        ),
                        SizedBox(width: 6.w),
                        Expanded(
                          child: Text(rows[i].$2,
                              style: TextStyle(
                                  fontSize: 12.sp, color: Colors.grey[800])),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionData {
  const _SectionData({required this.title, required this.blocks});
  final String title;
  final List<_Block> blocks;
}

class _HelpContent {
  const _HelpContent({
    required this.tldr,
    required this.sections,
    required this.disclaimer,
  });
  final String tldr;
  final List<_SectionData> sections;
  final String disclaimer;
}

// ─────────────────────────────────────── 中文 ───────────────────────────────────────

final _zhContent = _HelpContent(
  tldr: '某些网络到云主机公网地址的可达性不稳定。PrivateDeploy 会检测节点上游是否真正可用,'
      '并提供切换节点、重新部署节点、启用 Cloudflare Worker 入口等恢复选项。',
  sections: [
    _SectionData(
      title: '一句话原因',
      blocks: [
        _Para(
          '出现"上游不可达"提示时,通常表示本机隧道已经启动,但当前网络到所选节点公网地址的 TCP 路径没有稳定返回。'
          '原因可能是临时路由、网络策略、云厂商 IP 质量、防火墙规则或节点自身状态。',
        ),
      ],
    ),
    _SectionData(
      title: '应用会看什么',
      blocks: [
        _Para('PrivateDeploy 关注的是"能否到达你控制的节点",而不是只看本地开关是否已经打开:'),
        _CompareTable(
          headers: ('目标 IP', '结果'),
          rows: [
            ('198.51.100.15 (node)', 'TCP 连接超时', false),
            ('198.51.100.16 (node)', '同上', false),
            ('relay.example.com', 'HTTPS 入口可达', true),
          ],
        ),
        _Para('一个可用节点通常需要同时满足两件事:'),
        _CompareTable(
          headers: ('检查项', '结果'),
          rows: [
            ('节点监听端口', '可连接', true),
            ('健康探测', '可返回公网结果', true),
            ('本地隧道', '已启动', true),
          ],
        ),
        _Para(
          '如果本地隧道已启动但上游探测失败,界面会保留连接状态,同时提示你处理节点可达性问题。',
        ),
      ],
    ),
    _SectionData(
      title: '为什么会这样?',
      blocks: [
        _Para(
          '云主机公网地址的可达性会受多种因素影响:',
        ),
        _Bullet('移动网络、公司网络和公共 Wi-Fi 可能有不同的出口策略和防火墙规则。'),
        _Bullet('云厂商同一地区的 IP 段质量不完全一致,新建或更换节点后结果可能不同。'),
        _Bullet('节点安全组、系统防火墙、服务监听端口或证书配置错误也会造成同样现象。'),
        _Para(
          '因此,"本地已连接"和"业务流量可用"不是同一件事。应用会继续做上游探测,帮助你确认当前节点是否真正可用。',
        ),
      ],
    ),
    _SectionData(
      title: '你现在能做什么?',
      blocks: [
        _Bullet('① 切换网络:如果当前网络不可达,先尝试 Wi-Fi、移动网络或另一个受信任网络。', bold: true),
        _Bullet('② 切换到其他节点:在「云线路」列表里点击其他线路的"切换到此线路",应用会原地切换 outbound。'),
        _Bullet('③ 重新部署节点:如果某个节点长期不可达,重新部署可以获得新的云主机和安全组配置。'),
        _Bullet(
            '④ 启用 CDN 加速:在「设置 → CDN 加速」里配置 Cloudflare API token,应用会在你的 Cloudflare 账号下部署 Worker 入口,由 Worker 转发到你控制的 VPS。'),
        _Bullet('⑤ 检查服务器侧:确认服务端口已监听、安全组放行、系统时间正确,并且云主机没有超额或被暂停。'),
      ],
    ),
    _SectionData(
      title: '常见误解',
      blocks: [
        _Bullet('"换个协议就一定好了?" — 不一定。如果连接在到达节点前就超时,协议还没有机会开始协商。'),
        _Bullet('"一定是软件配错了?" — 不一定。先看节点端口、安全组和健康探测结果。'),
        _Bullet(
            '"Cloudflare Worker 会替代我的 VPS?" — 不会。Worker 只是你账号里的入口,最终仍转发到你控制的节点。'),
        _Bullet('"IPv6 一定更好?" — 不一定。取决于你的网络和云主机 IPv6 路由质量。'),
      ],
    ),
  ],
  disclaimer: '这些功能仅用于你拥有或已获授权的基础设施。请遵守所在地区、云服务商和网络服务商的使用规则。',
);

// ─────────────────────────────────────── English ───────────────────────────────────

final _enContent = _HelpContent(
  tldr:
      'Some networks have unstable reachability to public cloud host addresses. '
      'PrivateDeploy checks whether the selected node is actually usable and offers recovery options such as switching nodes, redeploying, or using your Cloudflare Worker endpoint.',
  sections: [
    _SectionData(
      title: 'In one line',
      blocks: [
        _Para(
          'When you see "upstream unreachable", the local tunnel has started but the current network is not getting a stable TCP path to the selected node. '
          'Possible causes include routing changes, network policy, cloud IP reputation, firewall rules, or node health.',
        ),
      ],
    ),
    _SectionData(
      title: 'What the app checks',
      blocks: [
        _Para(
            'PrivateDeploy looks for real node reachability, not just whether the local switch is on:'),
        _CompareTable(
          headers: ('Target IP', 'Result'),
          rows: [
            ('198.51.100.15 (node)', 'TCP timeout', false),
            ('198.51.100.16 (node)', 'same', false),
            ('relay.example.com', 'HTTPS endpoint reachable', true),
          ],
        ),
        _Para('A usable node normally needs these checks to pass:'),
        _CompareTable(
          headers: ('Check', 'Result'),
          rows: [
            ('Node listener', 'reachable', true),
            ('Health probe', 'returns egress result', true),
            ('Local tunnel', 'started', true),
          ],
        ),
        _Para(
          'If the local tunnel starts but upstream probes fail, the app keeps the connection state visible and points you to node reachability actions.',
        ),
      ],
    ),
    _SectionData(
      title: 'Why does this happen?',
      blocks: [
        _Para('Public cloud host reachability can vary for several reasons:'),
        _Bullet(
            'Mobile networks, office networks, and public Wi-Fi can apply different egress policies and firewall rules.'),
        _Bullet(
            'IP quality differs across cloud regions and providers; a newly deployed node may behave differently.'),
        _Bullet(
            'Security groups, local firewalls, listener ports, or certificate setup can create the same symptom.'),
        _Para(
          'That is why "locally connected" and "traffic is usable" are separate states. The app keeps probing upstream health to make that distinction clear.',
        ),
      ],
    ),
    _SectionData(
      title: 'What you can do now',
      blocks: [
        _Bullet(
          '① Switch networks: try Wi-Fi, mobile data, or another trusted network if the current network cannot reach the node.',
          bold: true,
        ),
        _Bullet(
          '② Switch to a different node: tap "Switch to this node" on another node in the cloud list. The app switches the outbound in place.',
        ),
        _Bullet(
          '③ Redeploy the node: if one node stays unreachable, redeploying creates a fresh host and security-group setup.',
        ),
        _Bullet(
          '④ Enable CDN acceleration: paste a Cloudflare API token in Settings → CDN acceleration. The app deploys a Worker endpoint in your Cloudflare account and relays to the VPS you control.',
        ),
        _Bullet(
          '⑤ Check the server side: confirm the service port is listening, the security group allows it, system time is correct, and the cloud account is not suspended or over quota.',
        ),
      ],
    ),
    _SectionData(
      title: 'Common misconceptions',
      blocks: [
        _Bullet(
            '"Will another protocol always fix it?" — Not necessarily. If the TCP path times out before reaching the node, protocol negotiation has not started yet.'),
        _Bullet(
            '"Is it definitely a software bug?" — Not necessarily. First check the node listener, security group, and health probes.'),
        _Bullet(
            '"Does Cloudflare Worker replace my VPS?" — No. It is only an endpoint in your account; traffic is still relayed to the node you control.'),
        _Bullet(
            '"Is IPv6 always better?" — Not always. It depends on your network and the cloud host IPv6 route quality.'),
      ],
    ),
  ],
  disclaimer:
      'Use these features only with infrastructure you own or are authorized to operate. Follow the rules of your jurisdiction, cloud provider, and network provider.',
);
