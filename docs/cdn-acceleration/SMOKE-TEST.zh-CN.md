# CDN 前置 —— 冒烟测试流程

[English](SMOKE-TEST.md) | **中文**

**状态:** v1, 2026-04-28
**负责人:** mobile + bridge
**范围:** 在一部真实手机上,通过一个真实的 Cloudflare Worker 前置一个真实的
Vultr 节点,从一个明确封锁裸 VPS IP 的网络环境出发,验证 Phase 4 + Phase 5
这条纵向链路能端到端跑通。

## 前置条件

| # | 要求 | 如何确认 |
| --- | --- | --- |
| 1 | 移动端应用从包含 Phase 4 + 5 的提交构建(build ≥ 33) | `Settings → About → Version` 显示 `(33)` 或更高 |
| 2 | 已部署一个 Vultr 节点,其 userdata 打开了 `VLESSRelayPort` | 机器上 `cat /etc/privatedeploy/vless/relay.json` 存在 |
| 3 | 一个免费 Cloudflare 账户,已认领 `*.workers.dev` 子域 | 访问 `dash.cloudflare.com → Workers & Pages` 显示你的子域 |
| 4 | 一部使用中国移动蜂窝网络的测试手机(或其他已知会过滤 VPS IP 的运营商) | 在 VPN 关闭的情况下,从手机执行 `curl -k https://<vps-ip>:443 --connect-timeout 5` 返回 `connect=0.000s exit=28` |

如果前置条件 4 不满足(即运营商当前没有过滤),本测试就没有意义 —— 在条件满足
之前先跳过。我们已确认该过滤是动态的;在"嘈杂"时段重试。

## Test 1 —— 通过应用部署 Worker

**目标:** 证明 `CdnProvider.deployWorkerForNode()` 正确地以 multipart 方式
上传脚本,并启用 workers.dev 子域。

1. 应用:**Settings → 帮助 → CDN 加速**。
2. 第 1 步:复制 CF dashboard URL,在浏览器中打开,用 `Edit Cloudflare Workers`
   模板创建 token,粘贴回第 2 步的输入框。
3. 点击 **Verify** —— 状态翻转为"已验证",并显示账户邮箱 + workers.dev 子域。
4. 滚动到 **你的节点** 区域。在一个显示了 `relay :<port>` 的节点(即拥有
   VLESSRelayPort)上点击 **部署 Worker**。
5. 等待约 3-5 秒。预期:
   - Snackbar:"Worker 已部署"
   - 行更新为以绿色显示 `pd-relay-<label>-<hash>.<sub>.workers.dev`
   - **Cloudflare dashboard** 现在在你的账户下列出了该脚本
6. 点击绿色 URL → "已复制" snackbar;将其粘贴到浏览器 → 看到
   "PrivateDeploy CDN relay" 落地页(HTTP 200)。

**通过标准:** 全部 6 步均成功完成,无需手动恢复。

## Test 2 —— 激活出站中的 CDN 变体

**目标:** 证明当部署被注册后,cloud_node_config_builder 会发出 CDN 出站。

1. 在同一应用会话中,前往 **节点 → cloud → <node>**。
2. 查看激活的配置(开发者菜单 / 日志)。
3. 确认 `outbounds` 数组中包含一个具有以下内容的成员:
   - `tag: "<label>-CDN"`
   - `type: "vless"`
   - `server: "<worker-host>.workers.dev"`
   - `server_port: 443`
   - `transport: { type: "ws", path: "/?ed=2560", headers.Host: "<worker-host>.workers.dev" }`
   - `tls.enabled: true, tls.server_name: "<worker-host>.workers.dev"`
4. 确认 urltest 选择器在其候选项中也列出了 `<label>-CDN`。

**通过标准:** 全部五个字段都存在且完全匹配。

## Test 3 —— 蜂窝绕过往返(真正的重点)

**目标:** 证明当运营商封锁裸 VPS IP 时,客户端流量仍能经由 worker → VPS
这一跳到达公网。

1. 手机处于蜂窝网络(VPN 关闭):确认 `curl -k --connect-timeout 5
   https://<vps-ip>:443/` 超时(`exit=28`)。
2. 确认 `curl --connect-timeout 5 https://<worker-host>.workers.dev/`
   返回 `200 OK` 并带有落地页(证明 CF 边缘 IP 可达)。
3. 通过应用连接到该 cloud 节点。第一轮探测可能选中 direct 出站并失败;此时
   sing-box 的 urltest 应在约 10 秒内选中 `-CDN` 变体。
4. 一旦橙色横幅消失,在浏览器中打开
   `https://api.ipify.org?format=json`。预期:返回 **VPS 公网 IP**
   (而不是 Cloudflare IP)。
5. 打开 `https://www.google.com/generate_204` —— 预期在 <500ms 内返回 HTTP 204。

**通过标准:**
- ipify 返回 VPS IP → 确认出口经由 VPS,而非经由 CF anycast
  (这正是我们想要的;CF 只是 L3 入口点)
- `generate_204` 成功 → 流量端到端贯通
- 没有橙色 UpstreamDegraded 横幅

## Test 4 —— 故障切换行为

**目标:** 证明 urltest 会根据哪一个健康,在 direct 与 CDN 变体之间自动路由。

1. 在 Wi-Fi 上连接时(direct 正常工作),确认激活的出站是 **direct** 变体
   (而非 `-CDN`)—— CDN 增加延迟,所以 urltest 应偏好 direct。
2. 在 VPN 已连接的情况下,将手机切换到蜂窝网络。urltest 应在约 30 秒内
   重新评估并切换到 `-CDN` 变体。
3. 切换回 Wi-Fi → urltest 回退到 direct。

**通过标准:** 在节点详情中可观察到的激活出站,在 sing-box 的 urltest 间隔内
于 direct 与 CDN 之间翻转,且对用户没有可见的断连。

## Test 5 —— 删除 Worker 完成清理

**目标:** 证明 `deleteWorkerForNode()` 会从 CF 移除脚本。

1. Settings → CDN 加速 → 点击已部署 Worker 旁的垃圾桶图标。
2. 确认对话框 → "已删除" / 状态行消失。
3. **Cloudflare dashboard:** 该脚本不再出现。
4. 在激活出站中重新测试同一节点 —— `-CDN` 变体应不再存在
   (CdnProvider 发出通知,generateNodeConfig 在不带该 host 的情况下重跑)。

## 需要在发布说明中点明的已知限制

- **userdata 变更之前创建的现有节点无法使用 CDN 前置。**
  部署 UI 会显示 "CDN unavailable (re-deploy)"。用户必须重新部署
  VPS 才能获得 VLESSRelayPort。
- **CF 免费层限制:** 每账户每天 10 万次请求 = 每个新连接计为 1 次请求。
  重度用户(持续约每小时 1k 连接)可能耗尽配额;在文档中点明此点。
- **延迟增量:** CF 边缘 → VPS 这一跳通常增加 50-150ms。在可达时仍偏好 direct。
- **每个节点一个 Worker:** 我们尚未通过 KV 支持的路由在多个节点间共享一个
  Worker。每个节点 = 一个脚本。CF 免费层允许 30 个脚本;对个人使用足够。

## 自动化测试桩

完整的冒烟测试需要一个实时蜂窝环境,因此无法在 CI 中运行。我们确实有一个
单元测试桩,它在不接入网络这一跳的情况下演练接线逻辑:

```dart
// test/cdn_outbound_builder_test.dart
test('CDN variant appears when worker host present and relay port set', () {
  final config = buildCloudNodeConfig(
    _instanceWithRelay(),
    cdnWorkerHost: 'pd-relay-foo.acme.workers.dev',
  );
  final outbounds = (jsonDecode(config!) as Map)['outbounds'] as List;
  final tags = outbounds.map((o) => o['tag']).toList();
  expect(tags, contains('vultr-CDN'));
});
```

(harness 模式参见 `test/cloud_node_config_builder_test.dart`。)

## 结果记录

| 日期 | Build | 运营商 | Test 1 | Test 2 | Test 3 | Test 4 | Test 5 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-04-28 | 33 | China Mobile 5G | manual-deferred | manual-deferred | manual-deferred | manual-deferred | manual-deferred | 实时部署需要真实的 CF token + 重新部署的 Vultr 节点。代码路径已通过 analyzer + 单元测试 + APK 构建验证。 |
