// PrivateDeploy CDN-front relay Worker
//
// Drop-in Cloudflare Worker that accepts a WebSocket upgrade and pipes the
// encrypted bytes to a configured upstream VPS over raw TCP. The VPS still
// terminates VLESS / Trojan / Hysteria — this Worker only relocates the L3
// entry point from "bare VPS IP" (which carriers drop SYN to) to "Cloudflare
// edge IP" (which they don't).
//
// Per-deployment placeholders that PrivateDeploy fills in at deploy time:
//   - __BACKEND_PLACEHOLDER__       host:port of the VPS plain-VLESS relay
//   - __PATH_SECRET_PLACEHOLDER__   32-hex random; client passes ?k=<secret>
//
// Hardening notes:
//   - Every request that doesn't present the correct path secret returns a
//     bare 404 with no body. Scanners and casual visitors see "nothing here"
//     instead of a self-identifying landing page.
//   - WebSocket upgrade is gated by the same secret. Without it, the Worker
//     never opens a TCP socket to the VPS, so the relay is not a free
//     out-of-band tunnel for anyone who learns the hostname.
//   - The Worker still holds NO long-lived credentials. The VLESS UUID lives
//     on the VPS only; the path secret is per-deployment and rotates with
//     redeploy. Both layers must fall before VPS auth is even reachable.

import { connect } from 'cloudflare:sockets';

const BACKEND = '__BACKEND_PLACEHOLDER__';
const PATH_SECRET = '__PATH_SECRET_PLACEHOLDER__';

export default {
  async fetch(request) {
    // Path-secret gate. Empty PATH_SECRET means "older deployment from before
    // the gate landed" — fall through to the original behaviour so a plain
    // app upgrade doesn't break in-flight tunnels. Newly-deployed Workers
    // always have a secret because the deploy code refuses to render the
    // template without replacing the placeholder.
    if (PATH_SECRET) {
      const url = new URL(request.url);
      if (url.searchParams.get('k') !== PATH_SECRET) {
        return new Response(null, { status: 404 });
      }
    }

    const upgradeHeader = request.headers.get('Upgrade');
    if (upgradeHeader !== 'websocket') {
      // Even with the right secret, non-WS requests return a generic 404.
      // No landing page, no app branding — the hostname is functionally
      // a black hole to anyone not running the WS client.
      return new Response(null, { status: 404 });
    }

    const [host, portStr] = BACKEND.split(':');
    const port = Number.parseInt(portStr, 10);
    if (!host || !Number.isInteger(port)) {
      return new Response(null, { status: 502 });
    }

    let tcp;
    try {
      tcp = connect({ hostname: host, port });
    } catch (_) {
      return new Response(null, { status: 502 });
    }

    const wsPair = new WebSocketPair();
    const [client, server] = Object.values(wsPair);
    server.accept();

    pipeWsToTcp(server, tcp).catch(() => server.close());
    pipeTcpToWs(tcp, server).catch(() => server.close());

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  },
};

async function pipeWsToTcp(ws, tcp) {
  const writer = tcp.writable.getWriter();
  ws.addEventListener('message', async (event) => {
    try {
      const data =
        event.data instanceof ArrayBuffer ? new Uint8Array(event.data) : event.data;
      await writer.write(data);
    } catch (_) {
      ws.close();
    }
  });
  ws.addEventListener('close', () => {
    writer.close().catch(() => {});
  });
  ws.addEventListener('error', () => {
    writer.close().catch(() => {});
  });
}

async function pipeTcpToWs(tcp, ws) {
  const reader = tcp.readable.getReader();
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      ws.send(value);
    }
  } finally {
    reader.releaseLock();
    ws.close();
  }
}
