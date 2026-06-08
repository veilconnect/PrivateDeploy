# Manual CDN-front deploy (Phase 1)

**English** | [中文](README.zh-CN.md)

Until PrivateDeploy automates Cloudflare Worker deployment from inside the app,
you can set up CDN acceleration manually in ~5 minutes. This document walks
through it.

## When you need this

Skip if your VPN is fine on Wi-Fi and on cellular. Only set up CDN front if
your phone shows the orange "upstream blocked" banner on cellular while Wi-Fi
works — that means your carrier (most often China Mobile 5G) is dropping SYN
to your VPS IP, and the fix is to reach your VPS via a Cloudflare edge IP
instead.

## Prerequisites

- A Cloudflare account (free).
- An existing PrivateDeploy node already deployed on a VPS, with a working
  VLESS-TLS endpoint. (You can see this in the app: the node's port and UUID
  are exposed in node detail / advanced.)

## Steps

### 1. Open the Workers dashboard

Go to `https://dash.cloudflare.com/`. If this is your first Worker, you'll be
prompted to choose a `*.workers.dev` subdomain — pick anything. Click
**Workers & Pages** in the sidebar.

### 2. Create a new Worker

Click **Create application → Create Worker**. Give it a name like
`pd-relay-myhouse`. Click **Deploy** to accept the default Hello-World; this
provisions the URL `https://pd-relay-myhouse.<your-subdomain>.workers.dev`.

### 3. Replace the script

Once deployed, click **Edit code** on the Worker. Delete everything in the
left editor and paste the contents of `worker.js` from this directory.

Find the line:

```js
const BACKEND = '__BACKEND_PLACEHOLDER__';
```

Replace it with your VPS's IP and VLESS-TLS port, in the form `host:port`.
Example:

```js
const BACKEND = '198.51.100.10:23953';
```

You can find this in your PrivateDeploy node detail: the IP under "Vultr ·
198.51.100.12 · vhp-1c-1gb-amd" and the VLESS port from the configured
outbound JSON.

Click **Save and deploy**.

### 4. Configure the client

In PrivateDeploy or any Clash-Meta-compatible client, add a new manual node
(or edit the existing one) with these parameters:

| Field | Value |
| --- | --- |
| Type | `vless` |
| Server | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| Port | `443` |
| UUID | (same UUID as your VPS-side VLESS server) |
| Network | `ws` |
| WebSocket path | `/?ed=2560` |
| WebSocket Host header | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| TLS | enabled |
| TLS SNI | `pd-relay-myhouse.<your-subdomain>.workers.dev` |
| Allow insecure | `false` |

Save and try to connect.

### 5. Verify it's actually using Cloudflare

Once connected, open `https://api.ipify.org` in your browser. The IP shown
should be your **VPS's public IP**, not Cloudflare's.

That's the giveaway that the relay is working: the client connects to a
Cloudflare edge IP (so the carrier sees Cloudflare and lets it through), but
the actual traffic exits to the internet from your VPS.

## Free-tier limits

- 100,000 Worker requests / day (each new connection = 1 request; long-lived
  WS connections count as 1 even if used for hours)
- 10ms CPU time / request (the relay uses ~0.5ms — never an issue)
- Up to 30 free-tier Workers per account

For personal use, you'll never hit these.

## Optional: path secret

If you set the `PATH_SECRET` constant in the Worker to a long random string,
clients must append `?k=<secret>` to their WebSocket path or get HTTP 403.
Use this if you're worried about the URL leaking and want a small extra wall.

The Worker holds no VLESS UUID, so even without the path secret an attacker
who finds your URL gets a TCP relay that they still need the VLESS UUID to
use — which only your VPS knows.

## Troubleshooting

**Client says "WebSocket handshake failed":**
- The Worker isn't deployed at the URL you pasted. Open the URL in a browser
  — you should see the "PrivateDeploy CDN relay" landing page.

**Client connects but no traffic:**
- BACKEND constant is wrong, or the VPS port is closed. Double-check
  `host:port` matches the VLESS port from your node config.

**Connects but slow / drops:**
- Cloudflare → VPS leg is the bottleneck. Try a different Cloudflare data
  center by setting your client's resolver to a different `dns-query`.
- Or your VPS is overloaded; check `top` / Vultr graphs.

**Want to disable temporarily without deleting the Worker:**
- Just switch the client back to the direct (non-CDN) node. The Worker
  stays deployed; nothing on Cloudflare's side changes.
