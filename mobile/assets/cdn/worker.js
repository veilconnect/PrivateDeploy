// PrivateDeploy CDN-front relay Worker
//
// Drop-in Cloudflare Worker that accepts a WebSocket upgrade at "/" and pipes
// the encrypted bytes to a configured upstream VPS over raw TCP. The VPS still
// terminates VLESS / Trojan / Hysteria — this Worker only relocates the L3
// entry point from "bare VPS IP" (which carriers drop SYN to) to "Cloudflare
// edge IP" (which they don't).
//
// Deploy:
//   1. Replace BACKEND with your VPS's reverse-proxy port (typically the
//      VLESS-TLS port from Vultr nodes JSON, e.g. 144.202.124.223:23953).
//   2. Save & deploy in Cloudflare Workers dashboard.
//   3. Enable the workers.dev subdomain for the Worker.
//   4. In your client, configure the node as VLESS-WS-TLS:
//        server:    <your-worker>.workers.dev
//        port:      443
//        type:      ws
//        path:      /?ed=2560
//        host:      <your-worker>.workers.dev
//        sni:       <your-worker>.workers.dev
//        UUID:      same as the VPS-side VLESS server
//
// The Worker holds NO credentials. If it leaks, an attacker still needs the
// VLESS UUID (held by the VPS) to terminate auth. Auditing this file means
// auditing the trust boundary.

import { connect } from 'cloudflare:sockets';

// Replace at deploy time. Format: "host:port".
const BACKEND = '__BACKEND_PLACEHOLDER__';

// Optional: if you want only requests from your installed clients to succeed,
// set a long random secret here and append "?k=<secret>" to the client's
// VLESS WebSocket path. Default is empty (no path-secret check).
const PATH_SECRET = '';

export default {
  async fetch(request) {
    const upgradeHeader = request.headers.get('Upgrade');
    if (upgradeHeader !== 'websocket') {
      return new Response(landingPage(), {
        status: 200,
        headers: { 'content-type': 'text/html; charset=utf-8' },
      });
    }

    if (PATH_SECRET) {
      const url = new URL(request.url);
      if (url.searchParams.get('k') !== PATH_SECRET) {
        return new Response('forbidden', { status: 403 });
      }
    }

    const [host, portStr] = BACKEND.split(':');
    const port = Number.parseInt(portStr, 10);
    if (!host || !Number.isInteger(port)) {
      return new Response('worker misconfigured: BACKEND not set', {
        status: 500,
      });
    }

    // Open TCP to the VPS first; if we can't reach it the WebSocket should
    // fail loudly rather than silently accept and stall.
    let tcp;
    try {
      tcp = connect({ hostname: host, port });
    } catch (err) {
      return new Response(`upstream connect failed: ${err}`, { status: 502 });
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
      if (done) {
        break;
      }
      ws.send(value);
    }
  } finally {
    reader.releaseLock();
    ws.close();
  }
}

function landingPage() {
  return `<!doctype html>
<meta charset="utf-8">
<title>PrivateDeploy CDN relay</title>
<style>body{font-family:system-ui;margin:40px auto;max-width:520px;color:#333}</style>
<h2>PrivateDeploy CDN relay</h2>
<p>This endpoint is a WebSocket relay. Clients connect via VLESS-WS-TLS;
this page is shown only to plain HTTP clients.</p>
<p>If you reached this URL by accident: nothing private is exposed here.</p>`;
}
