# 手动部署 CDN 前置(第一阶段)

[English](README.md) | **中文**

在 PrivateDeploy 实现从 App 内部自动部署 Cloudflare Worker 之前,
你可以在约 5 分钟内手动配置 CDN 加速。本文档将带你逐步完成。

## 何时需要它

如果你的 VPN 在 Wi-Fi 和蜂窝网络下都正常,则可跳过。只有当你的手机在
Wi-Fi 正常的情况下、在蜂窝网络下显示橙色的 "upstream blocked"(上游被阻断)
横幅时,才需要配置 CDN 前置——这意味着你的运营商(最常见的是中国移动 5G)
正在丢弃发往你 VPS IP 的 SYN 包,解决办法是改为通过 Cloudflare 边缘节点 IP
访问你的 VPS。

## 前置条件

- 一个 Cloudflare 账户(免费)。
- 一个已经部署在 VPS 上的现有 PrivateDeploy 节点,且具有可用的
  VLESS-TLS 端点。(你可以在 App 中查看:节点的端口和 UUID
  在节点详情 / 高级中暴露出来。)

## 步骤

### 1. 打开 Workers 仪表盘

访问 `https://dash.cloudflare.com/`。如果这是你的第一个 Worker,你会被
提示选择一个 `*.workers.dev` 子域名——随便选一个即可。点击侧边栏中的
**Workers & Pages**。

### 2. 创建一个新的 Worker

点击 **Create application → Create Worker**。给它起一个名字,例如
`pd-relay-myhouse`。点击 **Deploy** 以接受默认的 Hello-World;这会
预置 URL `https://pd-relay-myhouse.<your-subdomain>.workers.dev`。

### 3. 替换脚本

部署完成后,点击 Worker 上的 **Edit code**。删除左侧编辑器中的所有内容,
然后粘贴本目录下 `worker.js` 的内容。

找到这一行:

```js
const BACKEND = '__BACKEND_PLACEHOLDER__';
```

将其替换为你 VPS 的 IP 和 VLESS-TLS 端口,格式为 `host:port`。
示例:

```js
const BACKEND = '198.51.100.10:23953';
```

你可以在 PrivateDeploy 节点详情中找到它:"Vultr ·
198.51.100.12 · vhp-1c-1gb-amd" 下的 IP,以及来自已配置
outbound JSON 的 VLESS 端口。

点击 **Save and deploy**。

### 4. 配置客户端

在 PrivateDeploy 或任何兼容 Clash-Meta 的客户端中,添加一个新的手动节点
(或编辑现有的节点),使用以下参数:

| 字段 | 值 |
| --- | --- |
| Type | `vless` |
| Server | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| Port | `443` |
| UUID | (与你 VPS 端 VLESS 服务器相同的 UUID) |
| Network | `ws` |
| WebSocket path | `/?ed=2560` |
| WebSocket Host header | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| TLS | enabled |
| TLS SNI | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| Allow insecure | `false` |

保存并尝试连接。

### 5. 验证它确实在使用 Cloudflare

连接成功后,在浏览器中打开 `https://api.ipify.org`。显示的 IP
应该是你的 **VPS 的公网 IP**,而不是 Cloudflare 的。

这就是中继正常工作的标志:客户端连接到一个 Cloudflare 边缘节点 IP
(因此运营商看到的是 Cloudflare 并放行),但实际流量是从你的 VPS
出口到互联网的。

## 免费套餐限制

- 每天 100,000 次 Worker 请求(每个新连接 = 1 次请求;长连接的
  WS 连接即使使用数小时也只算 1 次)
- 每次请求 10ms CPU 时间(中继仅使用约 0.5ms——从来不是问题)
- 每个账户最多 30 个免费套餐 Worker

对于个人使用,你永远不会触及这些限制。

## 可选:路径密钥

如果你在 Worker 中将 `PATH_SECRET` 常量设置为一个很长的随机字符串,
客户端必须在其 WebSocket 路径后附加 `?k=<secret>`,否则会得到 HTTP 403。
如果你担心 URL 泄露并想要一道额外的小防线,可使用此功能。

Worker 不持有任何 VLESS UUID,因此即使没有路径密钥,一个发现了你 URL
的攻击者得到的也只是一个 TCP 中继,他们仍然需要 VLESS UUID 才能使用它
——而这只有你的 VPS 才知道。

## 故障排查

**客户端显示 "WebSocket handshake failed":**
- Worker 没有部署在你粘贴的那个 URL 上。在浏览器中打开该 URL
  ——你应该看到 "PrivateDeploy CDN relay" 落地页。

**客户端已连接但没有流量:**
- BACKEND 常量错误,或者 VPS 端口被关闭。仔细检查
  `host:port` 是否与你节点配置中的 VLESS 端口一致。

**已连接但缓慢 / 掉线:**
- Cloudflare → VPS 这一段是瓶颈。尝试通过将客户端的解析器设置为不同的
  `dns-query` 来使用不同的 Cloudflare 数据中心。
- 或者你的 VPS 过载了;检查 `top` / Vultr 图表。

**想要临时禁用而不删除 Worker:**
- 只需将客户端切换回直连(非 CDN)节点。Worker
  仍然保持部署状态;Cloudflare 一侧不会有任何变化。
