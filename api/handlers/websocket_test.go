package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

const testWSOrigin = "http://allowed.test"

type wsTestServer struct {
	server   *httptest.Server
	wsURL    string
	captured chan *websocket.Conn
	served   chan struct{}
}

func newWSTestServer(t *testing.T, hub *WSHub) *wsTestServer {
	t.Helper()
	gin.SetMode(gin.TestMode)

	captured := make(chan *websocket.Conn, 8)
	served := make(chan struct{}, 8)
	router := gin.New()
	router.GET("/ws", func(c *gin.Context) {
		hub.HandleWS(c)
		served <- struct{}{}
	})
	router.GET("/capture", func(c *gin.Context) {
		conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
		if err != nil {
			t.Errorf("upgrade capture connection: %v", err)
			return
		}
		captured <- conn
	})

	server := httptest.NewServer(router)
	t.Cleanup(server.Close)
	return &wsTestServer{
		server:   server,
		wsURL:    "ws" + strings.TrimPrefix(server.URL, "http"),
		captured: captured,
		served:   served,
	}
}

func (s *wsTestServer) dial(t *testing.T, path string) *websocket.Conn {
	t.Helper()
	header := http.Header{"Origin": []string{testWSOrigin}}
	conn, response, err := websocket.DefaultDialer.Dial(s.wsURL+path, header)
	if response != nil && response.Body != nil {
		defer response.Body.Close()
	}
	if err != nil {
		t.Fatalf("dial websocket %s: %v", path, err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	if path == "/ws" {
		select {
		case <-s.served:
		case <-time.After(2 * time.Second):
			t.Fatal("websocket handler did not finish registering client")
		}
	}
	return conn
}

func readWSMessage(t *testing.T, conn *websocket.Conn, timeout time.Duration) WSMessage {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("set websocket read deadline: %v", err)
	}
	var message WSMessage
	if err := conn.ReadJSON(&message); err != nil {
		t.Fatalf("read websocket message: %v", err)
	}
	return message
}

func TestWSHubFailedPeerDoesNotStopHub(t *testing.T) {
	hub := NewWSHub([]string{testWSOrigin})
	server := newWSTestServer(t, hub)

	// Register a connection whose next write is guaranteed to fail. This
	// specifically exercises the old self-unregister deadlock path rather than
	// relying on timing between the normal reader and writer goroutines.
	brokenPeer := server.dial(t, "/capture")
	brokenServerConn := <-server.captured
	brokenClient := hub.newClient(brokenServerConn)
	hub.register <- brokenClient
	<-brokenClient.ready
	go brokenClient.writePump()
	if err := brokenServerConn.Close(); err != nil {
		t.Fatalf("close server websocket: %v", err)
	}

	hub.Broadcast("trigger_failed_write", nil)

	// A failed peer must not prevent a subsequent client from registering and
	// receiving broadcasts.
	healthyPeer := server.dial(t, "/ws")
	hub.Broadcast("hub_still_running", map[string]bool{"ok": true})
	message := readWSMessage(t, healthyPeer, 2*time.Second)
	if message.Type != "hub_still_running" {
		t.Fatalf("message type = %q, want hub_still_running", message.Type)
	}
	_ = brokenPeer.Close()
}

func TestWSHubDropsSlowClientWithoutBlockingOthers(t *testing.T) {
	config := defaultWSHubConfig()
	config.sendBuffer = 1
	hub := newWSHub([]string{testWSOrigin}, config)
	server := newWSTestServer(t, hub)

	// Do not start a writer pump for this client. Its one-element queue fills on
	// the first broadcast, and the second broadcast must remove it immediately.
	slowPeer := server.dial(t, "/capture")
	slowServerConn := <-server.captured
	slowClient := hub.newClient(slowServerConn)
	hub.register <- slowClient
	<-slowClient.ready
	hub.Broadcast("fills_slow_queue", nil)
	hub.Broadcast("drops_slow_client", nil)

	healthyPeer := server.dial(t, "/ws")
	hub.Broadcast("delivered_after_slow_peer", "ok")
	message := readWSMessage(t, healthyPeer, 2*time.Second)
	if message.Type != "delivered_after_slow_peer" {
		t.Fatalf("message type = %q, want delivered_after_slow_peer", message.Type)
	}
	_ = slowPeer.Close()
}

func TestWSHubSerializesPingAndBroadcastWrites(t *testing.T) {
	config := defaultWSHubConfig()
	config.pingPeriod = time.Millisecond
	config.pongWait = 2 * time.Second
	config.sendBuffer = 2048
	hub := newWSHub([]string{testWSOrigin}, config)
	server := newWSTestServer(t, hub)
	peer := server.dial(t, "/ws")

	const (
		broadcasters = 4
		perWorker    = 200
	)
	var senders sync.WaitGroup
	senders.Add(broadcasters)
	for worker := 0; worker < broadcasters; worker++ {
		go func(worker int) {
			defer senders.Done()
			for sequence := 0; sequence < perWorker; sequence++ {
				hub.Broadcast("concurrent", fmt.Sprintf("%d:%d", worker, sequence))
			}
		}(worker)
	}

	for received := 0; received < broadcasters*perWorker; received++ {
		message := readWSMessage(t, peer, 5*time.Second)
		if message.Type != "concurrent" {
			t.Fatalf("message type = %q, want concurrent", message.Type)
		}
	}
	senders.Wait()
}
