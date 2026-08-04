package cdn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkerTemplatesWaitForUpstreamBeforeSwitchingProtocols(t *testing.T) {
	templates := map[string]string{
		"bridge": filepath.Join("assets", "worker.js"),
		"mobile": filepath.Join("..", "..", "mobile", "assets", "cdn", "worker.js"),
		"docs":   filepath.Join("..", "..", "docs", "cdn-acceleration", "worker.js"),
	}

	const openUpstreamBlock = `try {
      tcp = connect({ hostname: host, port });
      // connect() returns a Socket immediately; only ` + "`opened`" + ` proves that the
      // Worker actually established the upstream TCP connection. Do not send
      // 101 to the client until that promise resolves, otherwise an
      // unreachable relay is reported as a healthy WebSocket and then closes.
      await tcp.opened;
    } catch (_) {
      return new Response(null, { status: 502 });
    }`

	for name, path := range templates {
		name, path := name, path
		t.Run(name, func(t *testing.T) {
			sourceBytes, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			source := string(sourceBytes)
			if !strings.Contains(source, openUpstreamBlock) {
				t.Fatalf("%s must await tcp.opened and return 502 when opening fails", path)
			}

			openedAt := strings.Index(source, "await tcp.opened;")
			webSocketAt := strings.Index(source, "const wsPair = new WebSocketPair();")
			binaryTypeAt := strings.Index(source, "server.binaryType = 'arraybuffer';")
			acceptAt := strings.Index(source, "server.accept();")
			switchingProtocolsAt := strings.Index(source, "status: 101")
			if openedAt < 0 || webSocketAt < 0 || binaryTypeAt < 0 ||
				acceptAt < 0 || switchingProtocolsAt < 0 {
				t.Fatalf("%s is missing an upstream-open or WebSocket response marker", path)
			}
			if openedAt > webSocketAt || openedAt > switchingProtocolsAt {
				t.Fatalf("%s returns a WebSocket before the upstream TCP socket is open", path)
			}
			if binaryTypeAt > acceptAt {
				t.Fatalf("%s must select ArrayBuffer delivery before accepting WebSocket frames", path)
			}
		})
	}
}
