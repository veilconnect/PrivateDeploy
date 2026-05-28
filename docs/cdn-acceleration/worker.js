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
//
// Performance notes (one-direction pipeTo, May 2026):
//   - The download direction (TCP→WS, the dominant traffic direction for
//     web browsing) uses ReadableStream.pipeTo onto a WritableStream that
//     wraps ws.send. The Workers runtime executes pipeTo as a backpressured
//     V8 fast path — chunk forwarding happens in native code without a
//     per-chunk async hop through user JS. On the free tier (10 ms CPU/req)
//     that materially extends how long a tunnel can stay open before
//     getting CPU-budget-killed during large downloads.
//   - The upload direction (WS→TCP) keeps the original event-listener +
//     writer.write loop. Earlier we tried wrapping the WS event API in a
//     ReadableStream so both directions could pipeTo, but that variant
//     (commit 5ec9cf5) caused the runtime to throw at module instantiation
//     — every request returned CF error 1101 with no diagnostic detail.
//     Until we have a Worker tail consumer to capture the actual exception,
//     the WS→TCP wrapper stays on the proven manual path. Asymmetric, but
//     downloads are where the optimization matters most.

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
      // Accept the secret from EITHER the first path segment
      // (`/<secret>`) OR the `?k=<secret>` query param. sing-box's WS
      // dialer escapes query strings in transport.ws.path (it uses
      // max_early_data options, not the xray `?ed=` convention), so it
      // can only deliver the secret as a path segment. curl/Dart probes
      // send it as a query. Checking both keeps every client working.
      const pathSecret = url.pathname.replace(/^\/+/, '').split('/')[0];
      const querySecret = url.searchParams.get('k');
      if (pathSecret !== PATH_SECRET && querySecret !== PATH_SECRET) {
        return new Response(null, { status: 404 });
      }
    }

    // Header value is case-insensitive per RFC 6455 + RFC 7230 §3.2.
    // sing-box's WS dialer historically emitted "Upgrade: Websocket"
    // (capitalised W) on some builds, which a strict !== 'websocket'
    // check 404'd — silently breaking the entire VLESS-over-WS path
    // even though every other handshake field was correct.
    const upgradeHeader = request.headers.get('Upgrade')?.toLowerCase();
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

// WS → TCP: manual event-listener loop. See "Performance notes" header
// for why this direction stays on the proven path while the other side
// uses pipeTo.
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

// TCP → WS: tcp.readable is already a ReadableStream, so pipeTo into a
// thin WritableStream that hands each chunk to ws.send. The runtime owns
// the loop end-to-end, so we don't pay the per-chunk async-await
// round-trip the previous reader.read() version did.
async function pipeTcpToWs(tcp, ws) {
  await tcp.readable.pipeTo(
    new WritableStream({
      write(chunk) {
        ws.send(chunk);
      },
      close() {
        try {
          ws.close();
        } catch (_) {}
      },
      abort() {
        try {
          ws.close();
        } catch (_) {}
      },
    }),
  );
}
