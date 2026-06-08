# CDN 加速 — 设计文档

[English](CDN-ACCELERATION-DESIGN.md) | **中文**

**状态:** RFC · 2026-04-28
**负责人:** mobile + bridge
**追踪:** task #19

## 问题

中国移动蜂窝网络会对大多数主流服务商(Vultr/DO/Linode/AWS)的裸境外 VPS IP
丢弃 SYN。PrivateDeploy 的「自部署 VPS」架构为每个用户提供裸 IPv4 端点 ——
正是过滤的目标。测试数据显示,跨 6 个区域采样的 13 个 Vultr IP 中,
13/13 出现 TCP `connect=0.000s`、total=timeout,而域名 → CDN 边缘节点则在
约 250ms 内成功。

修复方案是结构性的:改变客户端连接的目标 IP,从裸 VPS IP 改为运营商不会过滤的
CDN 边缘 IP。CDN 将加密流量转发到用户的 VPS。无需更改协议或认证。

## 非目标

- 替换现有的直连流程。直连仍是默认方式;CDN 前置纯属附加功能。
- 为用户运行任何基础设施。每个用户使用自己的 Cloudflare 账号;
  PrivateDeploy 从不集中持有 CF 凭据。
- 解决每一家运营商的过滤。中国电信和联通通常可以直连;
  本功能专门针对中国移动蜂窝网络。

## 架构

### 高层流程

```
┌──────────┐    ws://*.workers.dev:443   ┌─────────────────┐    tcp        ┌──────────┐
│ client   │ ───────────────────────────▶│ Cloudflare edge │ ─────────────▶│ user VPS │
│ (mobile) │   (TLS, SNI=workers.dev)    │  + Worker (JS)  │   (any port)  │  (Vultr) │
└──────────┘                             └─────────────────┘               └──────────┘
        carrier sees only Cloudflare anycast IP
        (not in cellular blocklist)
```

Worker 是一个**简单的 WebSocket↔TCP 中继**:它在 `/` 接受 WS Upgrade,
打开一个到配置好的上游 VPS 的原始 TCP 连接,并在双向之间传递字节。
VPS 仍然负责终结真正的 VLESS / Trojan / Hysteria 认证。Worker 不会替换
VPS 的 VLESS 服务器 —— 它只是在 L3 入口点将 VPS IP 隐藏在 Cloudflare
边缘 IP 之后。

### 为什么用 WebSocket 而不是 WebSocket-VLESS?

有一种流行的 CF Worker 模式(zizifn/edgetunnel 及其衍生版本),
其中 Worker 自己实现 VLESS,从第一个 WS 帧解析协议头,提取目标地址,
并直接拨号。该模式众所周知,但有两项我们想要避免的成本:

1. **认证重复** —— Worker 持有 VLESS UUID 并充当信任边界。如果某个
   Worker 部署错误或其 UUID 泄露,VPS 就没有第二道墙。
2. **锁定** —— Worker 变得只针对单一协议。日后添加 Trojan 或 Hysteria
   就意味着每种协议都要有新的 Worker 变体。

相比之下,**WS↔TCP 中继**模式让 Worker 与协议无关且不含凭据。VPS 现有的
VLESS-TLS 端点仍是唯一的认证边界;我们只是通过 Worker 把它包装成
WS-over-TLS。

代价是多出一层 WS 帧封装(每个数据包几个字节,可忽略不计)。

### 为什么用 Workers 而不是 Tunnel?

`cloudflared` Tunnel 是替代方案。它运行在 VPS 上,向外拨号到 CF,由 CF 充当
入站方。优点:无需 Worker 代码,概念上更简单。缺点:

- 需要在我们部署的每个 VPS 上安装 `cloudflared` systemd 服务
  (更多 userdata 复杂度,更大的故障面)。
- 需要用户在 CF 中拥有一个域名(Tunnel 无法使用免费的
  `*.workers.dev` 子域名)。

Workers 不需要域名。用户注册时会自动获得 `<their-account>.workers.dev`。
这是摩擦最低的上手方式。

如果拥有自定义域名的用户更喜欢 Tunnel,我们日后可以将其作为第二种模式加入。

### 目录结构

```
bridge/cloud/cdn/
    cloudflare_client.go      // CF API: token verify, list accounts, deploy worker
    cloudflare_client_test.go
    worker_template.go        // Embeds the JS template (//go:embed)

docs/cdn-acceleration/
    worker.js                  // Source of truth for the Worker template
    README.md                  // Manual deploy instructions (fallback if API fails)

mobile/lib/features/cdn/
    cdn_provider.dart          // Holds CF token, deployed worker URL, per-node toggle
    cdn_settings_screen.dart   // Settings → Advanced → CDN acceleration entry
    cdn_token_input_dialog.dart

mobile/lib/features/vpn/
    vpn_outbound_cdn_wrap.dart // Transforms a node's outbound JSON to add WS layer
```

## 路径韧性(MVP 之后)

单 Worker 的 MVP 足以绕过蜂窝网络对裸 VPS IP 的 SYN 丢弃。但一旦进入生产环境,
仍有两种故障模式会降低质量:

1. **`*.workers.dev` 运营商限速。** 中国移动的中间盒会将 `workers.dev`
   识别为代理基础设施(在 tunnel-CN 社区中广为人知),并在流量持续几秒后施加
   选择性 TCP RST / 带宽上限。SYN 能通过;但*会话*会被降级。
   症状:握手很快,但吞吐量在约 30 秒内跌至约 50 KB/s。

2. **单一 CDN 成为单点故障。** Cloudflare 边缘从 CN 蜂窝网络的可达性
   因 colo 而异(HKG vs LAX vs NRT)。当 CF 降级时,每个用户都处于同一路径上,
   没有回退。

两项附加缓解措施:

### M1:Workers Custom Domains 绑定(绕过 workers.dev 模式)

如果用户在 Cloudflare 上拥有域名(Zone),我们使用 Cloudflare 的
Workers Custom Domains API 将同一个 Worker 脚本附加到该 zone 的某个子域名
(例如 `relay.example.com`)。运营商无法像指纹识别 `*.workers.dev` 那样指纹识别
个人域名 —— 它看起来和任何其他由 CF 前置的个人站点一样。

实现每次部署只用一个端点:`PUT /accounts/{aid}/workers/domains`,请求体为
`{hostname, service, zone_id, environment:"production"}`。Cloudflare 会自动
创建 DNS 记录和托管证书;清理只需一个
`DELETE /accounts/{aid}/workers/domains/{id}`(它会级联删除 DNS)。
已于 2026-05-09 从 CN 蜂窝网络经验证:自定义主机探测在第一次尝试就成功,
而同级的 workers.dev 探测则被 DNS 污染到非 CF IP 并超时。

- 新增 API 接口:`GET /zones`(仅用于选择器 UX)、
  `PUT /accounts/{aid}/workers/domains`、
  `DELETE /accounts/{aid}/workers/domains/{id}`。
- 所需 CF token 权限范围:`Account.Workers Scripts:Edit`、
  `Account.Account Settings:Read`、`Zone.Zone:Read`。早期的
  route+CNAME 实现所需的 `Zone.DNS:Edit` 和 `Zone.Workers Routes:Edit`
  权限范围不再需要 —— 最常见的坑(「Edit Cloudflare Workers」预设不授予
  zone 级权限范围)已经消失。
- UI:如果 `GET /zones` 返回 ≥1 个 zone,Settings 会显示一个带 zone 选择器的
  「Use custom domain」开关。默认关闭。
- Outbound 形态:客户端获得两个 outbound —— `cdn-default`
  (workers.dev)和 `cdn-custom`(自定义域名),与现有的 direct outbound 一起
  归入 `urltest` 之下。urltest 已经会选择延迟最低的可达路径;无需再接线其他东西。
- 成本:零(Workers Custom Domains 在同一 Workers 套餐中免费)。

### M2:同一 outbound 形态背后的次级 CDN

同样的 WS↔TCP 中继模式,部署在非 Cloudflare 边缘上。两个可行的次选
(按优先级排序):

1. **Fly.io** —— `flyctl deploy` 一个运行同样 WS↔TCP 中继代码的 64 MB Node 应用。
   HKG/SIN/NRT 的 Anycast IP。免费套餐在闲置/活跃额度内完全覆盖个人使用。
2. **Render.com** —— 类似,冷启动略高,但 hobby 套餐无需信用卡。

为什么不用 Fastly Compute@Edge 或 Bunny Edge Scripts:

- Fastly Compute@Edge 仅通过 beta API 支持原始 WS Upgrade;部署工具链
  (`fastly` CLI + Rust/Go 目标)比 `flyctl` 更重。
- Bunny edge scripting 仅限付费套餐。

实现:`bridge/cloud/cdn/` 会新增一个与 CloudProvider 抽象并行的 `provider`
接口,包含 `cloudflare_provider.go` 和 `flyio_provider.go`。一旦主 CDN 健康,
mobile UI 就会显示「Add backup CDN」。两个 CDN outbound + direct 都进入同一个
urltest 组;sing-box 会选择最先响应的那个。

### 故障转移实际上是如何触发的

我们不编写自定义看门狗。该机制**已经存在于 sing-box 中**:

- 所有路径(`direct`、`cdn-default`、`cdn-custom`、`cdn-fallback-flyio`)
  都是同一个 `urltest` outbound 中的同级。`interval=1m`,`tolerance=50ms`。
- urltest 每分钟通过现有 UpstreamDegraded 分类器已经使用的同一个 `gstatic`
  204 端点探测每个路径(见 `frontend/src/utils/coreHealthMonitor.ts`)。
- 当运营商在会话中途对 workers.dev 限速时,urltest 的下一次探测会失败或超时
  → 流量在下一个新连接上转移到次优路径。长连接会通过新路径重新建立。

唯一的新代码是 *outbound 生成* —— 在启用 CDN 时把一个节点的配置变成多路径的
urltest 组。它位于 `vpn_outbound_cdn_wrap.dart`,是一个确定性变换,无运行时状态。

## 面向用户的流程

### 首次设置

1. 用户注意到蜂窝网络上橙色的 UpstreamDegraded 横幅,并阅读 Help 屏幕
   (已在 #18 中发布)。Help 将 CDN 加速提及为选项 ④,目前标注「计划中」,
   但在 #19 之后将显示「可用 —— Settings → CDN acceleration」。

2. 用户打开 **Settings → CDN acceleration**(新条目,位于设置列表中
   「Help」下方)。

3. 屏幕显示:
   > **通过 Cloudflare 的蜂窝网络回退**
   >
   > 如果你家里的 Wi-Fi 可用,但蜂窝网络持续显示「upstream blocked」,
   > 你可以将流量通过运营商不会过滤的 Cloudflare 边缘 IP 路由。
   > 这需要一个免费的 Cloudflare 账号;PrivateDeploy 仅用它将一个小型的
   > 中继 Worker 部署到你的账号中。
   >
   > **我的数据会怎样?** 它仍然端到端加密地流向你的 VPS。Cloudflare 只能看到
   > 加密字节。Cloudflare 和 PrivateDeploy 永远看不到你的 VLESS UUID 或你的
   > 流量内容。
   >
   > [Set up CDN acceleration]

4. 点击 → token 输入对话框,内嵌指向 CF dashboard 的链接
   (`https://dash.cloudflare.com/profile/api-tokens`)以及一行说明:
   「Create a token with **Edit Cloudflare Workers** template.」

5. 用户粘贴 token → 应用调用 `cloudflare_client.VerifyToken()` → 确认
   account ID,呈现账号 email + workers.dev 子域名。

6. 应用调用 `cloudflare_client.DeployWorker()` → 注册
   `pd-relay-<random>.workers.dev`,将用户各节点的上游地址嵌入 Worker 配置,
   返回 URL。

7. 出现每节点的 CDN 开关。默认关闭。打开 → 该节点的 sing-box outbound 被
   重写为使用 WS-over-TLS 连接到 worker URL。

### 连接时

如果某节点同时启用了 CDN 和直连,sing-box 配置会同时包含两个 outbound,
外加一个 urltest 选择器,优先选择直连(延迟更低),并回退到 CDN 前置的 outbound。
早前工作中的三态分类器会自动捕捉到这一变化 —— 如果直连失败
(UpstreamDegraded),urltest 就会进行故障转移。

(这是最干净的交接:当直连可用时,用户获得全速;当直连在蜂窝网络上中断时,
urltest 会无需用户操作地自动通过 CF 路由。)

## CF API 接口

我们使用 v4 REST API 配合用户提供的 API token。所需权限范围:
`Edit Cloudflare Workers`(dashboard 中的预设模板)。

端点:

- `GET /user/tokens/verify` —— 确认 token 有效性,获取 account_id。
- `GET /accounts/{id}/subdomain` —— 获取用户的 `*.workers.dev` 子域名。
  如果子域名尚未注册,此处返回 404 → 应用提示用户在 dashboard 中领取一个
  (一键,约 10 秒)。
- `PUT /accounts/{id}/workers/scripts/{name}` —— 上传 Worker JS。
  Multipart 请求体,包含脚本和元数据。
- `POST /accounts/{id}/workers/scripts/{name}/subdomain` —— 为脚本启用
  workers.dev 路由。

Worker 命名模式:`pd-relay-<7-char-random>`,这样并发的 PrivateDeploy 安装
不会在同一账号上发生冲突。

## Worker 模板

见 `docs/cdn-acceleration/worker.js`。关键特性:

- 约 80 行,无外部 import,运行在 Workers 免费套餐上。
- 在任意路径接受 WS Upgrade(我们会用 `/`,但任何路径都可以)。
- 从部署时的 `BACKEND` 常量读取上游 `host:port`
  (上传前已渲染进脚本中)。
- 使用 Cloudflare 的 `connect()` API(TCP outbound)拨号上游。
- 在双向之间传递字节,直到任一方关闭。

免费套餐限制:每天 100k 请求。每个 WS 连接 = 1 个请求。
典型的浏览会话约为每分钟 10–50 个新连接 → 对个人使用而言轻松处于免费套餐之内。

## 安全与隐私考量

- **Token** 通过 `flutter_secure_storage` 存储(在其他地方已用于云服务商凭据)。
  从不记录日志,默认从不进入备份。
- **Worker 代码** 在 `docs/cdn-acceleration/worker.js` 以明文形式可审计。
  我们从不部署混淆代码。
- **不涉及 PrivateDeploy 服务器。** Token → 从设备直接到 CF API。
  无服务端中继;不对 token 使用进行任何分析统计。
- **CF 处只有加密字节。** Worker 看到的是 WS 包装的 TLS 流;
  在没有 VLESS UUID 的情况下无法解密,而该 UUID 从不离开设备→VPS。
- **Worker 配置不包含 UUID。** Worker 只知道上游 `host:port`;
  认证仍在客户端与 VPS 之间进行。

## 测试计划

1. 针对录制的 CF 响应 Cassette 对 `cloudflare_client` 进行单元测试。
2. 手动冒烟测试:将真实 Worker 部署到真实 CF 账号,验证客户端能通过它连接。
3. 蜂窝绕过测试:从中国移动 5G 经由 CDN 前置节点连接 VPN,确认
   `https://api.ipify.org` 返回 VPS IP(而非 Cloudflare IP —— Cloudflare
   只是 L3 中继)。
4. 横幅回归:在启用 CDN 的情况下,确保 UpstreamDegraded 不会触发 ——
   直连失败,urltest 自动经 CDN 路由,分类器经由 gstatic 看到隧道可达,
   返回 Healthy。

## 分阶段交付

| 阶段 | 范围 | 文件 |
| --- | --- | --- |
| 1 | Worker 模板 + 手动部署文档(无需应用集成即可工作) | `docs/cdn-acceleration/*` |
| 2 | CF API 客户端(Go)+ token 验证/部署 | `bridge/cloud/cdn/*` |
| 3 | Settings UI + token 存储(尚不部署) | `mobile/lib/features/cdn/cdn_settings_screen.dart` |
| 4 | 经 UI 部署 + 每节点开关 | 接通阶段 1–3 |
| 5 | Outbound 变换(带 direct + CDN 的 urltest) | `mobile/lib/features/vpn/vpn_outbound_cdn_wrap.dart` |
| 6 | 蜂窝冒烟测试、打磨、在特性开关后发布 | — |
| 7 | M1:Workers Custom Domains 绑定(`workers.dev` 限速绕过) | `bridge/cdn/cdn_routes.go`(zones + attach/detach),settings UI zone 选择器 |
| 8 | M2:Fly.io 次级 CDN 提供方(单 CDN 故障绕过) | `bridge/cloud/cdn/provider.go`、`flyio_provider.go`,settings UI「Add backup CDN」 |

阶段 1 是今天即可交付的价值;具备必要技能的用户可以手动部署 Worker 并配置其客户端。
阶段 2–6 降低了这种摩擦。阶段 7–8 是 MVP 之后的韧性(见「路径韧性」一节),
只有在生产数据显示 workers.dev 限速或单 CDN 可达性缺口足以证明新增接口面合理时
才会启用。

## 开放问题

1. 我们是否应为拥有自定义域名的用户提供「Tunnel 模式」替代方案?
   —— 已被阶段 7 的自定义域名 Worker 路由(M1)涵盖。Tunnel 本身仍被推迟;
   同样的 UX(在 CF zone 上使用自定义域名)现在可以通过 Worker 路径实现,
   而无需在 VPS 上安装 `cloudflared`。
2. 用 KV 支持多节点配置,让一个 Worker 服务多个 VPS 目标,还是每个节点一个
   Worker? —— 先从每个节点一个 Worker 开始(更简单);如果免费套餐的
   30-Worker 限制成为问题,再重新考虑。
3. 故障转移门控:urltest 是否应检测「CDN 比直连慢」并在稳态下偏好直连?
   —— 是。使用 sing-box 的 urltest,设 `interval=10m`,即现有模式。
   一旦 M1+M2 落地,同一 urltest 组会新增两个同级(`cdn-custom`、
   `cdn-fallback-flyio`);无逻辑变更。
4. 当 M2 落地时,我们是想要每个用户的次级 CDN 凭据,还是由 PrivateDeploy
   运营的共享 Fly.io 应用? —— 每个用户,与 M1 相同。这保持了「无中央基础设施」
   这一非目标的完整性,并避免我们持有用户流量。代价是为选择加入的用户多出一个
   上手步骤。
