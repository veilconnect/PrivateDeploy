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
  tldr: '蜂窝运营商对"用户独立部署的海外 VPS 裸 IP"做 SYN 丢包,但对"通过域名走 CDN 的 HTTPS 流量"较宽松。'
      'PrivateDeploy 自部署的节点用的是 Vultr/DO/Linode 等云厂商的裸 IPv4——这正是被运营商重点过滤的范围。'
      'Wi-Fi 通常没有此问题。',
  sections: [
    _SectionData(
      title: '一句话原因',
      blocks: [
        _Para(
          '出现"上游不可达"提示时,问题通常出在你的运营商和 VPS 提供商 IP 段之间——'
          '不是 PrivateDeploy 软件配错,也不是节点服务挂了。',
        ),
      ],
    ),
    _SectionData(
      title: '用真实测试数据说明',
      blocks: [
        _Para('测试环境:移动网络 5G,VPN 已断开(直连测试):'),
        _Para('完全连不通(裸 IP):'),
        _CompareTable(
          headers: ('目标 IP', '结果'),
          rows: [
            ('198.51.100.14 (Vultr)', 'TCP SYN 丢弃,5 秒超时', false),
            ('198.51.100.12 (Vultr)', '同上', false),
            ('1.1.1.1 (Cloudflare DNS)', '同上', false),
            ('8.8.8.8 (Google DNS)', '同上', false),
          ],
        ),
        _Para('正常连通(域名经 CDN):'),
        _CompareTable(
          headers: ('目标域名', '结果'),
          rows: [
            ('vultr.com', '316 ms · 200 OK', true),
            ('cloudflare.com', '247 ms · 200 OK', true),
            ('www.taobao.com (国内)', '54 ms · 200 OK', true),
          ],
        ),
        _Para(
          '关键观察:连接耗时为 0 但总时长是超时上限——意味着 TCP 三次握手的 SYN 包发出后'
          '一个回应都没收到,这是运营商主动丢包的特征,不是网络拥塞。',
        ),
      ],
    ),
    _SectionData(
      title: '为什么会这样?',
      blocks: [
        _Para(
          '蜂窝运营商的 DPI(深度包检测)对国际段流量按"宁可错杀"原则过滤:',
        ),
        _Bullet('裸 IP 直连 HTTPS = 高度怀疑(普通用户极少这样上网),进 IP 黑名单或动态丢 SYN。'),
        _Bullet('域名 → CDN 边缘 IP = 较低怀疑(海量正常网站走 CDN,完封会误伤)。'),
        _Para(
          'Vultr / DigitalOcean / Linode 等 VPS 提供商的整段 IP 都打上了"VPN 友好"标签。'
          '运营商按段过滤,与你跑什么协议无关——shadowsocks、Hysteria2、VLESS、Trojan 全部一样,'
          'SYN 都送不到服务器。',
        ),
      ],
    ),
    _SectionData(
      title: '你现在能做什么?',
      blocks: [
        _Bullet(
            '① 切到 Wi-Fi(最快):家里 / 公司 Wi-Fi 国际段过滤通常比蜂窝松得多。'
            '90% 的用户日常其实在 Wi-Fi,这条路覆盖大部分场景。',
            bold: true),
        _Bullet('② 切换到其他节点:在「云线路」列表里点击其他线路的"切换到此线路",'
            '应用会原地切换 outbound,不会断开 VPN。新部署的、地理位置较冷门的节点'
            '(法兰克福 / 圣保罗)有时比 LAX/NRT 等热门区域更容易透过来。'),
        _Bullet('③ 切到不同的 SIM 卡运营商:移动网络 / 电信 / 联通的不可达策略不同步。'
            '移动网络 5G 在敏感时段封得最狠,电信和联通通常稍宽松。'),
        _Bullet('④ 启用 CDN 加速:在「设置 → CDN 加速」里粘贴 Cloudflare API token,'
            '应用会在你的 Cloudflare 账号下自动部署一个中转 Worker——客户端连 Cloudflare '
            '边缘 IP(运营商不封),Worker 再转发到你的 VPS。需要节点用最新的 userdata 重新部署一次。'),
      ],
    ),
    _SectionData(
      title: '常见误解',
      blocks: [
        _Bullet('"换个协议就好了?" — 不是。SYN 在 TCP 第一步就被丢,任何协议都跑不起来。'),
        _Bullet('"Vultr 是不是被整个封了?" — 不是 Vultr 被针对,所有大型 VPS 提供商的 IP 段都在过滤范围。'),
        _Bullet('"为什么我朋友用魔戒就没事?" — 商业 VPN 服务花大力气运维专门规避不可达的中转节点,不是普通自部署能做到的。'),
        _Bullet('"那 IPv6 呢?" — IPv6 受同样的过滤,换 IPv6 没用。'),
      ],
    ),
  ],
  disclaimer: '这是中国蜂窝运营商和"自部署 VPN"产品形态之间的结构性矛盾,无法靠一次软件更新一劳永逸解决。'
      '当前版本能做到的是诚实告知和提供切换工具,长期方案是 CDN 前置(规划中)。',
);

// ─────────────────────────────────────── English ───────────────────────────────────

final _enContent = _HelpContent(
  tldr:
      "Chinese mobile carriers drop SYN packets to bare offshore VPS IPs but allow HTTPS via CDN-fronted "
      "domains. PrivateDeploy's nodes use bare Vultr/DO/Linode IPv4, which falls in the dropped range. "
      "Wi-Fi usually doesn't have this issue.",
  sections: [
    _SectionData(
      title: 'In one line',
      blocks: [
        _Para(
          'When you see "upstream unreachable", it is almost always between your cellular carrier '
          'and your VPS provider — not a PrivateDeploy bug or a server outage.',
        ),
      ],
    ),
    _SectionData(
      title: 'What we measured',
      blocks: [
        _Para('Test setup: mobile carrier 5G, VPN disabled (direct probe):'),
        _Para('Bare IPs — all dropped:'),
        _CompareTable(
          headers: ('Target IP', 'Result'),
          rows: [
            ('198.51.100.14 (Vultr)', 'TCP SYN dropped, 5 s timeout', false),
            ('198.51.100.12 (Vultr)', 'same', false),
            ('1.1.1.1 (Cloudflare DNS)', 'same', false),
            ('8.8.8.8 (Google DNS)', 'same', false),
          ],
        ),
        _Para('CDN-fronted domains — all OK:'),
        _CompareTable(
          headers: ('Domain', 'Result'),
          rows: [
            ('vultr.com', '316 ms · 200 OK', true),
            ('cloudflare.com', '247 ms · 200 OK', true),
            ('www.taobao.com (domestic)', '54 ms · 200 OK', true),
          ],
        ),
        _Para(
          'Connect time is 0 but the total time hits the deadline — meaning the TCP SYN '
          'never received an ACK. That signature is active packet drop by the carrier, '
          'not congestion.',
        ),
      ],
    ),
    _SectionData(
      title: 'Why does this happen?',
      blocks: [
        _Para(
            'Carrier DPI applies an "over-block" policy to international traffic:'),
        _Bullet(
            'Bare-IP HTTPS = highly suspicious (rare for normal users) → IP blacklist or SYN drop.'),
        _Bullet(
            'Domain → CDN edge = lower suspicion (huge volume of legit sites and apps).'),
        _Para(
          'Vultr/DigitalOcean/Linode IP ranges have been broadly tagged as "VPN-friendly" '
          'and are filtered as a class. Protocol choice (Shadowsocks, Hysteria2, VLESS, Trojan) '
          'does not help — the SYN never reaches the server in the first place.',
        ),
      ],
    ),
    _SectionData(
      title: 'What you can do now',
      blocks: [
        _Bullet(
          '① Switch to Wi-Fi (fastest): home/office Wi-Fi typically has much weaker '
          'international filtering than cellular. ~90 % of usage is on Wi-Fi anyway.',
          bold: true,
        ),
        _Bullet(
          '② Switch to a different node: tap "Switch to this node" on another node in the cloud list. '
          'Newer or less-popular regions (Frankfurt, São Paulo) sometimes punch through when '
          'LAX/NRT are blocked.',
        ),
        _Bullet(
          '③ Try a different SIM carrier: mobile carrier blocks the hardest, especially during '
          'sensitive periods. Telecom and Unicom are typically a bit looser.',
        ),
        _Bullet(
          '④ Enable CDN acceleration: paste a Cloudflare API token in '
          'Settings → CDN acceleration; the app deploys a relay Worker into '
          'your CF account. Clients connect to the Cloudflare edge IP '
          '(which carriers do not block) and the Worker forwards to your '
          'VPS. Requires re-deploying the node with the latest userdata.',
        ),
      ],
    ),
    _SectionData(
      title: 'Common misconceptions',
      blocks: [
        _Bullet(
            '"Will another protocol work?" — No. The SYN is dropped at TCP layer, before any protocol.'),
        _Bullet(
            '"Is Vultr specifically blocked?" — No. All major VPS providers fall in the filtered range.'),
        _Bullet(
            '"Why does Mojie/Surge etc. work for my friend?" — Commercial network services run constantly-rotated relay infrastructure, which a single self-deployed VPS cannot match.'),
        _Bullet(
            '"What about IPv6?" — IPv6 has the same filter behavior. No improvement.'),
      ],
    ),
  ],
  disclaimer:
      'This is a structural tension between Chinese cellular carriers and the "self-deployed VPN" '
      'product shape — no single software update can fix it for good. Right now PrivateDeploy '
      'is honest about it and gives you switching tools; the long-term answer is CDN fronting (planned).',
);
