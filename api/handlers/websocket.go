package handlers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"privatedeploy/api/models"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		// Origin filtering is enforced in HandleWS before upgrade.
		return true
	},
}

const (
	defaultWSWriteWait  = 10 * time.Second
	defaultWSPongWait   = 60 * time.Second
	defaultWSPingPeriod = 30 * time.Second
	defaultWSSendBuffer = 256
	defaultWSReadLimit  = 64 * 1024
)

var errWSControlQueueFull = errors.New("websocket control queue is full")

// WSMessage represents a WebSocket message.
type WSMessage struct {
	Type string      `json:"type"`
	Data interface{} `json:"data"`
}

type wsHubConfig struct {
	writeWait  time.Duration
	pongWait   time.Duration
	pingPeriod time.Duration
	sendBuffer int
	readLimit  int64
}

func defaultWSHubConfig() wsHubConfig {
	return wsHubConfig{
		writeWait:  defaultWSWriteWait,
		pongWait:   defaultWSPongWait,
		pingPeriod: defaultWSPingPeriod,
		sendBuffer: defaultWSSendBuffer,
		readLimit:  defaultWSReadLimit,
	}
}

type wsFrame struct {
	messageType int
	payload     []byte
}

// wsClient owns one websocket connection. Only writePump may call websocket
// write methods; readPump forwards control replies to it instead of writing
// from the reader goroutine.
type wsClient struct {
	hub     *WSHub
	conn    *websocket.Conn
	send    chan []byte
	control chan wsFrame
	ready   chan struct{}
	done    chan struct{}
	once    sync.Once
}

func (c *wsClient) close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *wsClient) queueControl(messageType int, payload []byte) bool {
	frame := wsFrame{messageType: messageType, payload: append([]byte(nil), payload...)}
	select {
	case <-c.done:
		return false
	case c.control <- frame:
		return true
	default:
		return false
	}
}

func (c *wsClient) readPump() {
	defer func() {
		c.hub.unregisterClient(c)
		c.close()
	}()

	c.conn.SetReadLimit(c.hub.config.readLimit)
	_ = c.conn.SetReadDeadline(time.Now().Add(c.hub.config.pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(c.hub.config.pongWait))
	})
	c.conn.SetPingHandler(func(payload string) error {
		if !c.queueControl(websocket.PongMessage, []byte(payload)) {
			return errWSControlQueueFull
		}
		return nil
	})

	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure, websocket.CloseAbnormalClosure) {
				log.Printf("[WSHub] ERROR: Unexpected close: %v", err)
			}
			return
		}
	}
}

func (c *wsClient) writePump() {
	ticker := time.NewTicker(c.hub.config.pingPeriod)
	defer func() {
		ticker.Stop()
		c.hub.unregisterClient(c)
		c.close()
	}()

	write := func(messageType int, payload []byte) error {
		if err := c.conn.SetWriteDeadline(time.Now().Add(c.hub.config.writeWait)); err != nil {
			return err
		}
		return c.conn.WriteMessage(messageType, payload)
	}

	for {
		select {
		case <-c.done:
			return
		case payload := <-c.send:
			if err := write(websocket.TextMessage, payload); err != nil {
				log.Printf("[WSHub] ERROR: Failed to write message: %v", err)
				return
			}
		case frame := <-c.control:
			if err := write(frame.messageType, frame.payload); err != nil {
				return
			}
		case <-ticker.C:
			if err := write(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// WSHub manages WebSocket connections.
type WSHub struct {
	clients    map[*wsClient]struct{}
	broadcast  chan WSMessage
	register   chan *wsClient
	unregister chan *wsClient
	origins    []string
	config     wsHubConfig
}

// NewWSHub creates a new WebSocket hub.
func NewWSHub(allowedOrigins []string) *WSHub {
	return newWSHub(allowedOrigins, defaultWSHubConfig())
}

func newWSHub(allowedOrigins []string, config wsHubConfig) *WSHub {
	hub := &WSHub{
		clients:    make(map[*wsClient]struct{}),
		broadcast:  make(chan WSMessage, 256),
		register:   make(chan *wsClient, 256),
		unregister: make(chan *wsClient, 256),
		origins:    append([]string(nil), allowedOrigins...),
		config:     config,
	}

	go hub.run()
	return hub
}

func (h *WSHub) newClient(conn *websocket.Conn) *wsClient {
	return &wsClient{
		hub:     h,
		conn:    conn,
		send:    make(chan []byte, h.config.sendBuffer),
		control: make(chan wsFrame, 8),
		ready:   make(chan struct{}),
		done:    make(chan struct{}),
	}
}

func (h *WSHub) unregisterClient(client *wsClient) {
	h.unregister <- client
}

func (h *WSHub) removeClient(client *wsClient) bool {
	if _, ok := h.clients[client]; !ok {
		return false
	}
	delete(h.clients, client)
	client.close()
	return true
}

// run starts the WebSocket hub event loop. It never performs network I/O, so
// one failed or slow peer cannot stop registration or delivery to other peers.
func (h *WSHub) run() {
	for {
		select {
		case client := <-h.register:
			h.clients[client] = struct{}{}
			close(client.ready)
			log.Printf("[WSHub] Client connected, total clients: %d", len(h.clients))

		case client := <-h.unregister:
			if h.removeClient(client) {
				log.Printf("[WSHub] Client disconnected, total clients: %d", len(h.clients))
			}

		case message := <-h.broadcast:
			payload, err := json.Marshal(message)
			if err != nil {
				log.Printf("[WSHub] ERROR: Failed to encode message: %v", err)
				continue
			}
			for client := range h.clients {
				select {
				case client.send <- payload:
				default:
					// A full queue means the peer cannot keep up. Remove it here;
					// never self-send to unregister from inside the hub loop.
					h.removeClient(client)
					log.Printf("[WSHub] Slow client disconnected, total clients: %d", len(h.clients))
				}
			}
		}
	}
}

// Broadcast sends a message to all connected clients.
func (h *WSHub) Broadcast(msgType string, data interface{}) {
	h.broadcast <- WSMessage{
		Type: msgType,
		Data: data,
	}
}

// HandleWS handles WebSocket connections.
func (h *WSHub) HandleWS(c *gin.Context) {
	origin := strings.TrimSpace(c.GetHeader("Origin"))
	if !isWebSocketOriginAllowed(origin, h.origins) {
		c.JSON(http.StatusForbidden, models.ErrorResponse(
			models.ErrUnauthorized,
			"Origin is not allowed",
		))
		return
	}

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("[WSHub] ERROR: Failed to upgrade connection: %v", err)
		return
	}

	client := h.newClient(conn)
	h.register <- client
	<-client.ready
	go client.writePump()
	go client.readPump()
}

func isWebSocketOriginAllowed(origin string, allowedOrigins []string) bool {
	// Non-browser websocket clients may not send Origin.
	if origin == "" {
		return true
	}

	if len(allowedOrigins) == 0 {
		return false
	}

	for _, allowed := range allowedOrigins {
		trimmed := strings.TrimSpace(allowed)
		if trimmed == "*" {
			return true
		}
		if strings.EqualFold(trimmed, origin) {
			return true
		}
	}
	return false
}

// BroadcastVPNStatus broadcasts VPN status change.
func (h *WSHub) BroadcastVPNStatus(status, profileID string) {
	h.Broadcast("vpn_status", gin.H{
		"status":    status,
		"profileId": profileID,
	})
}

// BroadcastTrafficUpdate broadcasts traffic statistics.
func (h *WSHub) BroadcastTrafficUpdate(upload, download, uploadSpeed, downloadSpeed int64) {
	h.Broadcast("traffic_update", gin.H{
		"upload":        upload,
		"download":      download,
		"uploadSpeed":   uploadSpeed,
		"downloadSpeed": downloadSpeed,
	})
}

// BroadcastInstanceStatus broadcasts cloud instance status change.
func (h *WSHub) BroadcastInstanceStatus(instanceID, status string) {
	h.Broadcast("instance_status", gin.H{
		"id":     instanceID,
		"status": status,
	})
}
