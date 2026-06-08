# CDN Front-End — Smoke Test Procedure

**English** | [中文](SMOKE-TEST.zh-CN.md)

**Status:** v1, 2026-04-28
**Owner:** mobile + bridge
**Scope:** verify the Phase 4 + Phase 5 vertical works end-to-end on a real
phone against a real Cloudflare Worker fronting a real Vultr node, from a
network that demonstrably blocks the bare VPS IP.

## Pre-conditions

| # | Requirement | How to confirm |
| --- | --- | --- |
| 1 | Mobile app built from a commit that includes Phase 4 + 5 (build ≥ 33) | `Settings → About → Version` shows `(33)` or higher |
| 2 | A Vultr node deployed with userdata that opens `VLESSRelayPort` | `cat /etc/privatedeploy/vless/relay.json` on the box exists |
| 3 | A free Cloudflare account with `*.workers.dev` subdomain claimed | Visit `dash.cloudflare.com → Workers & Pages` shows your subdomain |
| 4 | A test phone on China Mobile cellular (or another carrier known to filter VPS IPs) | `curl -k https://<vps-ip>:443 --connect-timeout 5` returns `connect=0.000s exit=28` from the phone with VPN off |

If pre-condition 4 fails (i.e. the carrier doesn't currently filter), the
test is meaningless — skip until conditions are met. We've confirmed the
filter is dynamic; retry during a "noisy" period.

## Test 1 — Worker deploy via app

**Goal:** prove `CdnProvider.deployWorkerForNode()` correctly multipart-uploads
the script and enables the workers.dev subdomain.

1. App: **Settings → 帮助 → CDN 加速**.
2. Step 1: copy CF dashboard URL, open in a browser, create token with
   the `Edit Cloudflare Workers` template, paste back into Step 2's input.
3. Tap **Verify** — status flips to "已验证" with account email + workers.dev
   subdomain shown.
4. Scroll to **你的节点** section. Tap **部署 Worker** on a node that has
   `relay :<port>` shown (i.e. has VLESSRelayPort).
5. Wait ~3-5 seconds. Expected:
   - Snackbar: "Worker 已部署"
   - Row updates to show `pd-relay-<label>-<hash>.<sub>.workers.dev` in green
   - **Cloudflare dashboard** now lists the script under your account
6. Tap the green URL → "已复制" snackbar; paste it into a browser → see the
   "PrivateDeploy CDN relay" landing page (HTTP 200).

**Pass criteria:** all 6 steps succeed without manual recovery.

## Test 2 — CDN variant in active outbound

**Goal:** prove the cloud_node_config_builder emits the CDN outbound when
the deployment is registered.

1. From the same app session, go to **节点 → cloud → <node>**.
2. View the active config (developer menu / log).
3. Confirm the `outbounds` array contains a member with:
   - `tag: "<label>-CDN"`
   - `type: "vless"`
   - `server: "<worker-host>.workers.dev"`
   - `server_port: 443`
   - `transport: { type: "ws", path: "/?ed=2560", headers.Host: "<worker-host>.workers.dev" }`
   - `tls.enabled: true, tls.server_name: "<worker-host>.workers.dev"`
4. Confirm the urltest selector also lists `<label>-CDN` among its candidates.

**Pass criteria:** All five fields are present and exactly match.

## Test 3 — Cellular bypass round-trip (the actual point)

**Goal:** prove client traffic, when the carrier blocks bare VPS IP, still
reaches the public internet via the worker → VPS leg.

1. Phone on cellular (VPN off): confirm `curl -k --connect-timeout 5
   https://<vps-ip>:443/` times out (`exit=28`).
2. Confirm `curl --connect-timeout 5 https://<worker-host>.workers.dev/`
   returns `200 OK` with the landing page (proves CF edge IP is reachable).
3. Connect via the app to the cloud node. The first probe round may pick
   the direct outbound and fail; sing-box's urltest should then pick the
   `-CDN` variant within ~10 seconds.
4. Once the orange banner clears, open a browser to
   `https://api.ipify.org?format=json`. Expected: returns the **VPS public
   IP** (NOT a Cloudflare IP).
5. Open `https://www.google.com/generate_204` — expect HTTP 204 in <500ms.

**Pass criteria:**
- ipify returns VPS IP → confirms egress is via VPS, not via CF anycast
  (which is what we want; CF is only the L3 entry point)
- `generate_204` succeeds → traffic flows end-to-end
- No orange UpstreamDegraded banner

## Test 4 — Failover behavior

**Goal:** prove urltest auto-routes between direct and CDN variants based
on which is healthy.

1. While connected on Wi-Fi (where direct works fine), confirm the active
   outbound is the **direct** variant (not `-CDN`) — CDN adds latency, so
   urltest should prefer direct.
2. Switch the phone to cellular while VPN is connected. urltest should
   re-evaluate within ~30s and switch to the `-CDN` variant.
3. Switch back to Wi-Fi → urltest reverts to direct.

**Pass criteria:** the active outbound observable in node detail flips
between direct and CDN within sing-box's urltest interval, without any
user-visible disconnection.

## Test 5 — Worker delete cleans up

**Goal:** prove `deleteWorkerForNode()` removes the script from CF.

1. Settings → CDN 加速 → tap the trash icon next to a deployed Worker.
2. Confirm dialog → "已删除" / status row disappears.
3. **Cloudflare dashboard:** the script no longer appears.
4. Re-test the same node in the active outbound — the `-CDN` variant should
   no longer be present (CdnProvider notifies, generateNodeConfig re-runs
   without the host).

## Known limitations to call out in a release note

- **Existing nodes from before the userdata change can't use CDN front-end.**
  The deploy UI shows "CDN unavailable (re-deploy)". User has to re-deploy
  the VPS to get VLESSRelayPort.
- **CF free-tier limits:** 100k requests/day per account = each new
  connection counts as 1 request. Heavy users (~1k connections/hour
  sustained) could exhaust the quota; surface this in docs.
- **Latency adder:** CF edge → VPS leg adds 50-150ms typically. Direct stays
  preferred when reachable.
- **One Worker per node:** we don't yet share a Worker across nodes via
  KV-backed routing. Each node = one script. CF free tier allows 30 scripts;
  fine for personal use.

## Automated test stub

The full smoke test requires a live cellular environment, so it can't run
in CI. We do have a unit-test stub that exercises the wiring without the
network leg:

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

(See `test/cloud_node_config_builder_test.dart` for the harness pattern.)

## Result log

| Date | Build | Carrier | Test 1 | Test 2 | Test 3 | Test 4 | Test 5 | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-04-28 | 33 | China Mobile 5G | manual-deferred | manual-deferred | manual-deferred | manual-deferred | manual-deferred | live deploy needs real CF token + re-deployed Vultr node. Code path verified by analyzer + unit tests + APK builds. |
