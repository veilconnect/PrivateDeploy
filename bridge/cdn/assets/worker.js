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
// Performance notes:
//   - Both directions use ReadableStream.pipeTo() instead of manual
//     read/write loops. pipeTo is implemented in the Workers runtime as a
//     backpressured V8 fast path: chunk forwarding + buffer reuse happen
//     in native code, with no per-chunk async user-code hop. On the free
//     tier (10 ms CPU/request) this materially extends how long a tunnel
//     can stay open before getting CPU-budget-killed.
//   - The WebSocket → TCP direction wraps the WS event API in a
//     ReadableStream so the same pipeTo() path applies. Closing semantics
//     mirror the old loop: either end closing tears the other side down.

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

    // Both directions are pipeTo() onto the runtime's native streams. On
    // any error we tear both sides down; the catch handlers swallow
    // (close-after-close is fine and logging would just burn CPU).
    pipeWsToTcp(server, tcp).catch(() => closeBoth(server, tcp));
    pipeTcpToWs(tcp, server).catch(() => closeBoth(server, tcp));

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  },
};

// pipeWsToTcp wraps the WebSocket event API in a ReadableStream so the
// runtime's pipeTo() can shuttle bytes into tcp.writable without a
// per-chunk async hop. WS messages arrive as ArrayBuffer (binary VLESS)
// or string (very rare here); we normalize ArrayBuffer → Uint8Array so
// downstream writers see one shape.
async function pipeWsToTcp(ws, tcp) {
  const wsReadable = new ReadableStream({
    start(controller) {
      ws.addEventListener('message', (event) => {
        try {
          const data =
            event.data instanceof ArrayBuffer
              ? new Uint8Array(event.data)
              : event.data;
          controller.enqueue(data);
        } catch (_) {
          // Enqueue can throw if the stream is already closed — fine to
          // swallow because the close listener (or the matching pipeTo
          // tear-down) will end the relay anyway.
        }
      });
      ws.addEventListener('close', () => {
        try {
          controller.close();
        } catch (_) {}
      });
      ws.addEventListener('error', () => {
        try {
          controller.error(new Error('ws error'));
        } catch (_) {}
      });
    },
  });
  await wsReadable.pipeTo(tcp.writable);
}

// pipeTcpToWs walks tcp.readable straight into a WritableStream that
// hands every chunk to ws.send. The runtime owns the loop, so we don't
// pay the per-chunk async-await round-trip the previous reader.read()
// version did.
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

function closeBoth(ws, tcp) {
  try {
    ws.close();
  } catch (_) {}
  try {
    tcp.close();
  } catch (_) {}
}
