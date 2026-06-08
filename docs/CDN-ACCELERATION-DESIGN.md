# CDN Acceleration — Design Doc

**English** | [中文](CDN-ACCELERATION-DESIGN.zh-CN.md)

**Status:** RFC · 2026-04-28
**Owner:** mobile + bridge
**Tracking:** task #19

## Problem

China Mobile cellular drops SYN to bare offshore VPS IPs across most major
providers (Vultr/DO/Linode/AWS). PrivateDeploy's "self-deployed VPS" architecture
gives every user bare IPv4 endpoints — exactly the filter target. Test data
 shows TCP `connect=0.000s`, total=timeout for
13/13 sampled Vultr IPs across 6 regions, while domain → CDN edge succeeds in
~250ms.

The fix is structural: change the destination IP that the client connects to,
from a bare VPS IP to a CDN edge IP that carriers don't filter. The CDN forwards
the encrypted traffic to the user's VPS. No protocol or auth change.

## Non-goals

- Replace the existing direct-connect flow. Direct stays the default;
  CDN-front is purely additive.
- Run any infrastructure for users. Each user brings their own Cloudflare
  account; PrivateDeploy never holds CF credentials centrally.
- Solve every carrier's filter. CN Telecom and Unicom often work direct;
  this feature targets China Mobile cellular specifically.

## Architecture

### High-level flow

```
┌──────────┐    ws://*.workers.dev:443   ┌─────────────────┐    tcp        ┌──────────┐
│ client   │ ───────────────────────────▶│ Cloudflare edge │ ─────────────▶│ user VPS │
│ (mobile) │   (TLS, SNI=workers.dev)    │  + Worker (JS)  │   (any port)  │  (Vultr) │
└──────────┘                             └─────────────────┘               └──────────┘
        carrier sees only Cloudflare anycast IP
        (not in cellular blocklist)
```

The Worker is a **dumb WebSocket↔TCP relay**: it accepts WS Upgrade at `/`,
opens a raw TCP connection to the configured upstream VPS, and pipes bytes in
both directions. The VPS still terminates the actual VLESS / Trojan / Hysteria
auth. The Worker does NOT replace the VPS's VLESS server — it just hides the
VPS IP behind a Cloudflare edge IP at the L3 entry point.

### Why WebSocket and not WebSocket-VLESS?

There is a popular CF Worker pattern (zizifn/edgetunnel and clones) where the
Worker speaks VLESS itself, parses the protocol header from the first WS frame,
extracts the destination, and dials directly. That pattern is well-known but
has two costs we want to avoid:

1. **Auth duplication** — the Worker holds the VLESS UUID and acts as the
   trust boundary. If a Worker is misdeployed or its UUID leaks, the VPS
   has no second wall.
2. **Lock-in** — the Worker becomes specific to one protocol. Adding Trojan
   or Hysteria later means new Worker variants per protocol.

By contrast, the **WS↔TCP relay** pattern keeps the Worker protocol-agnostic
and credential-free. The VPS's existing VLESS-TLS endpoint stays the only
auth boundary; we just wrap it in WS-over-TLS through the Worker.

The cost is one extra WS framing layer (a few bytes per packet, negligible).

### Why Workers and not Tunnel?

`cloudflared` Tunnel is the alternative. It runs on the VPS, dials out to
CF, and CF acts as the inbound. Pros: no Worker code, simpler conceptually.
Cons:

- Requires installing `cloudflared` systemd service on every VPS we deploy
  (more userdata complexity, more failure surface).
- Requires the user to own a domain in CF (Tunnel does not work with the
  free `*.workers.dev` subdomain).

Workers don't need a domain. The user gets `<their-account>.workers.dev`
automatically when they sign up. That is the lowest-friction onboarding.

We can add Tunnel as a second mode later if users with custom domains
prefer it.

### Directory layout

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

## Path resilience (post-MVP)

The single-Worker MVP is enough to bypass cellular SYN-drop on bare VPS IPs.
But two failure modes still degrade quality once we're in production:

1. **`*.workers.dev` operator throttling.** China Mobile's middleboxes
   recognise `workers.dev` as proxy infrastructure (well-known among
   tunnel-CN community) and apply selective TCP RST / bandwidth caps after
   a few seconds of traffic. SYN gets through; the *session* degrades.
   Symptom: handshake fast, throughput collapses to ~50 KB/s within ~30 s.

2. **Single CDN as a single point of failure.** Cloudflare's edge
   reachability from CN cellular varies by colo (HKG vs LAX vs NRT).
   When CF degrades, every user is on the same path with no fallback.

Two additive mitigations:

### M1: Workers Custom Domains binding (bypasses workers.dev pattern)

If the user owns a domain on Cloudflare (Zone), we attach the same Worker
script to a subdomain of that zone (e.g., `relay.example.com`) using
Cloudflare's Workers Custom Domains API. Operators can't fingerprint a
personal domain the way they fingerprint `*.workers.dev` — it looks like
any other CF-fronted personal site.

The implementation uses a single endpoint per deploy:
`PUT /accounts/{aid}/workers/domains` with body
`{hostname, service, zone_id, environment:"production"}`. Cloudflare
auto-creates the DNS record and the managed cert; cleanup is one
`DELETE /accounts/{aid}/workers/domains/{id}` (which cascades the DNS).
Empirically validated on 2026-05-09 from a CN-cellular network: a
custom-host probe succeeded on the first attempt while the
sibling workers.dev probe DNS-poisoned to a non-CF IP and timed out.

- API surface adds: `GET /zones` (only for the picker UX),
  `PUT /accounts/{aid}/workers/domains`,
  `DELETE /accounts/{aid}/workers/domains/{id}`.
- Required CF token scopes: `Account.Workers Scripts:Edit`,
  `Account.Account Settings:Read`, `Zone.Zone:Read`. The
  `Zone.DNS:Edit` and `Zone.Workers Routes:Edit` scopes that the
  earlier route+CNAME implementation needed are no longer required —
  the most common foot-gun (the "Edit Cloudflare Workers" preset
  doesn't grant zone-level scopes) is gone.
- UI: if `GET /zones` returns ≥1 zone, Settings shows a "Use custom
  domain" toggle with a zone picker. Default off.
- Outbound shape: client gets two outbounds — `cdn-default`
  (workers.dev) and `cdn-custom` (custom-domain), grouped under
  `urltest` with the existing direct outbound. urltest already picks
  the lowest-latency reachable path; nothing else to wire.
- Cost: zero (Workers Custom Domains are free on the same Workers plan).

### M2: Secondary CDN behind the same outbound shape

Same WS↔TCP relay pattern, deployed on a non-Cloudflare edge. Two viable
seconds (in priority order):

1. **Fly.io** — `flyctl deploy` a 64 MB Node app running the same WS↔TCP
   relay code. Anycast IPs in HKG/SIN/NRT. Free tier covers personal use
   well within idle/active limits.
2. **Render.com** — similar, slightly higher cold-start, but no card
   required for hobby tier.

Why not Fastly Compute@Edge or Bunny Edge Scripts:

- Fastly Compute@Edge supports raw WS Upgrade only via beta APIs; deploy
  toolchain (`fastly` CLI + Rust/Go target) is heavier than `flyctl`.
- Bunny edge scripting is paid-plan only.

Implementation: `bridge/cloud/cdn/` grows a `provider` interface
parallel to the CloudProvider abstraction, with `cloudflare_provider.go`
and `flyio_provider.go`. The mobile UI surfaces "Add backup CDN" once
the primary is healthy. Both CDN outbounds + direct go into the same
urltest group; sing-box picks whichever responds first.

### How the failover actually fires

We do not write a custom watchdog. The mechanism is **already in sing-box**:

- All paths (`direct`, `cdn-default`, `cdn-custom`, `cdn-fallback-flyio`)
  are siblings in one `urltest` outbound. `interval=1m`, `tolerance=50ms`.
- urltest probes each every minute via the same `gstatic` 204 endpoint
  the existing UpstreamDegraded classifier already uses (see
  `frontend/src/utils/coreHealthMonitor.ts`).
- When operator throttles workers.dev mid-session, urltest's next probe
  fails or times out → traffic shifts to the next-best path on the next
  new connection. Long-lived connections re-establish via the new path.

The only new code is the *outbound generation* — turning one node's
config into a multi-path urltest group when CDN is enabled. That lives in
`vpn_outbound_cdn_wrap.dart` and is a deterministic transform, no
runtime state.

## User-facing flow

### First-time setup

1. User notices the orange UpstreamDegraded banner on cellular and reads the
   Help screen (already shipped in #18). Help mentions CDN acceleration as
   option ④, "planned" today, but post-#19 will say "available — Settings →
   CDN acceleration".

2. User opens **Settings → CDN acceleration** (new entry, lives below
   "Help" in the settings list).

3. Screen reads:
   > **Cellular fallback via Cloudflare**
   >
   > If your home Wi-Fi works but cellular keeps showing "upstream blocked",
   > you can route traffic through Cloudflare's edge IPs which carriers don't
   > filter. This needs a free Cloudflare account; PrivateDeploy uses it only
   > to deploy a small relay Worker into your account.
   >
   > **What happens to my data?** It still flows end-to-end encrypted to your
   > VPS. Cloudflare sees encrypted bytes only. Cloudflare and PrivateDeploy
   > never see your VLESS UUID or your traffic content.
   >
   > [Set up CDN acceleration]

4. Tap → token input dialog with embedded link to CF dashboard
   (`https://dash.cloudflare.com/profile/api-tokens`) and a one-line
   instruction: "Create a token with **Edit Cloudflare Workers** template."

5. User pastes token → app calls `cloudflare_client.VerifyToken()` → confirms
   account ID, surfaces account email + workers.dev subdomain.

6. App calls `cloudflare_client.DeployWorker()` → registers
   `pd-relay-<random>.workers.dev`, embeds the user's nodes' upstream
   addresses into the Worker config, returns the URL.

7. Per-node CDN toggle appears. Off by default. Toggle on → that node's
   sing-box outbound is rewritten to use WS-over-TLS to the worker URL.

### When connecting

If a node has CDN enabled and direct, sing-box config has BOTH outbounds
plus a urltest selector that prefers direct (lower latency) and falls back to
the CDN-fronted outbound. The three-state classifier from earlier work picks
up the change automatically — if direct fails (UpstreamDegraded), the urltest
fails over.

(This is the cleanest handoff: when direct works, user gets full speed;
when direct breaks on cellular, urltest auto-routes through CF without user
action.)

## CF API surface

We use the v4 REST API with a user-supplied API token. Required scope:
`Edit Cloudflare Workers` (preset template in dashboard).

Endpoints:

- `GET /user/tokens/verify` — confirm token validity, get account_id.
- `GET /accounts/{id}/subdomain` — fetch user's `*.workers.dev` subdomain.
  If the subdomain isn't yet registered, this returns 404 → app prompts user
  to claim one in dashboard (one-click, ~10s).
- `PUT /accounts/{id}/workers/scripts/{name}` — upload Worker JS.
  Multipart body with the script and metadata.
- `POST /accounts/{id}/workers/scripts/{name}/subdomain` — enable
  workers.dev routing for the script.

Worker name pattern: `pd-relay-<7-char-random>` so concurrent
PrivateDeploy installs don't collide on the same account.

## Worker template

See `docs/cdn-acceleration/worker.js`. Key properties:

- ~80 lines, no external imports, runs on Workers free tier.
- Accepts WS Upgrade at any path (we'll use `/` but anything works).
- Reads upstream `host:port` from the deploy-time `BACKEND` constant
  (rendered into the script before upload).
- Uses Cloudflare's `connect()` API (TCP outbound) to dial upstream.
- Pipes bytes in both directions until either side closes.

Free-tier limits: 100k requests/day. Each WS connection = 1 request.
A typical browsing session is ~10–50 new connections per minute → easily
within free tier for personal use.

## Security & privacy considerations

- **Token** stored via `flutter_secure_storage` (already used elsewhere
  for cloud provider creds). Never logged, never in backups by default.
- **Worker code** is auditable in plaintext at `docs/cdn-acceleration/worker.js`.
  We never deploy obfuscated code.
- **No PrivateDeploy server involvement.** Token → CF API directly from
  the device. No server-side relay; no analytics on token use.
- **Encrypted bytes only at CF.** Worker sees the WS-wrapped TLS stream;
  cannot decrypt without the VLESS UUID, which never leaves device→VPS.
- **Worker config does NOT include the UUID.** Worker only knows the
  upstream `host:port`; auth still happens between client and VPS.

## Test plan

1. Unit test `cloudflare_client` against a recorded Cassette of CF responses.
2. Manual smoke test: deploy real Worker to a real CF account, verify
   client can connect through it.
3. Cellular bypass test: from China Mobile 5G with VPN connected via
   CDN-fronted node, confirm `https://api.ipify.org` returns the VPS IP
   (not Cloudflare IP — Cloudflare is just the L3 relay).
4. Banner regression: with CDN enabled, ensure UpstreamDegraded does NOT
   trigger — direct fails, urltest auto-routes via CDN, classifier sees
   tunnel reachable through gstatic, returns Healthy.

## Phased delivery

| Phase | Scope | Files |
| --- | --- | --- |
| 1 | Worker template + manual-deploy docs (works without app integration) | `docs/cdn-acceleration/*` |
| 2 | CF API client (Go) + token verify/deploy | `bridge/cloud/cdn/*` |
| 3 | Settings UI + token storage (no deploy yet) | `mobile/lib/features/cdn/cdn_settings_screen.dart` |
| 4 | Deploy via UI + per-node toggle | wires phases 1–3 |
| 5 | Outbound transformation (urltest with direct + CDN) | `mobile/lib/features/vpn/vpn_outbound_cdn_wrap.dart` |
| 6 | Cellular smoke test, polish, ship behind feature flag | — |
| 7 | M1: Workers Custom Domains binding (`workers.dev` throttle bypass) | `bridge/cdn/cdn_routes.go` (zones + attach/detach), settings UI zone picker |
| 8 | M2: Fly.io secondary CDN provider (single-CDN failure bypass) | `bridge/cloud/cdn/provider.go`, `flyio_provider.go`, settings UI "Add backup CDN" |

Phase 1 is the value-deliverable today; users with the necessary skill can
deploy the Worker manually and configure their client. Phases 2–6 reduce that
friction. Phases 7–8 are post-MVP resilience (see "Path resilience" section)
and only kick in once production data shows workers.dev throttling or
single-CDN reachability gaps justify the added surface.

## Open questions

1. Should we offer a "Tunnel mode" alternative for users with custom domains?
   — Subsumed by Phase 7's custom-domain Worker route (M1). Tunnel itself
   stays deferred; the same UX (custom domain on a CF zone) is now reachable
   through the Worker path without `cloudflared` on the VPS.
2. KV-backed multi-node config so one Worker serves multiple VPS targets vs
   one Worker per node? — Start with one Worker per node (simpler); revisit
   if free-tier 30-Worker limit becomes an issue.
3. Failover gate: should urltest detect "CDN slower than direct" and prefer
   direct in steady state? — Yes. Use sing-box's urltest with `interval=10m`,
   the existing pattern. Once M1+M2 land, the same urltest group gains two
   more siblings (`cdn-custom`, `cdn-fallback-flyio`); no logic change.
4. When M2 lands, do we want per-user secondary-CDN credentials, or a
   PrivateDeploy-operated shared Fly.io app? — Per-user, same as M1. Keeps
   the "no central infrastructure" non-goal intact and avoids us holding
   user traffic. Trade-off is one more onboarding step for users who opt in.
