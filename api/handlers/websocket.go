package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"privatedeploy/api/utils"
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

// WSMessage represents a WebSocket message
type WSMessage struct {
	Type string      `json:"type"`
	Data interface{} `json:"data"`
}

// WSHub manages WebSocket connections
type WSHub struct {
	clients    map[*websocket.Conn]bool
	broadcast  chan WSMessage
	register   chan *websocket.Conn
	unregister chan *websocket.Conn
	jwtSecret  string
	origins    []string
	mu         sync.RWMutex
}

// NewWSHub creates a new WebSocket hub
func NewWSHub(jwtSecret string, allowedOrigins []string) *WSHub {
	hub := &WSHub{
		clients:    make(map[*websocket.Conn]bool),
		broadcast:  make(chan WSMessage, 256),
		register:   make(chan *websocket.Conn),
		unregister: make(chan *websocket.Conn),
		jwtSecret:  jwtSecret,
		origins:    allowedOrigins,
	}

	go hub.run()

	return hub
}

// run starts the WebSocket hub event loop
func (h *WSHub) run() {
	for {
		select {
		case conn := <-h.register:
			h.mu.Lock()
			h.clients[conn] = true
			h.mu.Unlock()
			log.Printf("[WSHub] Client connected, total clients: %d", len(h.clients))

		case conn := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[conn]; ok {
				delete(h.clients, conn)
				conn.Close()
			}
			h.mu.Unlock()
			log.Printf("[WSHub] Client disconnected, total clients: %d", len(h.clients))

		case message := <-h.broadcast:
			h.mu.RLock()
			for conn := range h.clients {
				err := conn.WriteJSON(message)
				if err != nil {
					log.Printf("[WSHub] ERROR: Failed to write message: %v", err)
					conn.Close()
					h.mu.RUnlock()
					h.unregister <- conn
					h.mu.RLock()
				}
			}
			h.mu.RUnlock()
		}
	}
}

// Broadcast sends a message to all connected clients
func (h *WSHub) Broadcast(msgType string, data interface{}) {
	h.broadcast <- WSMessage{
		Type: msgType,
		Data: data,
	}
}

// HandleWS handles WebSocket connections
func (h *WSHub) HandleWS(c *gin.Context) {
	origin := strings.TrimSpace(c.GetHeader("Origin"))
	if !isWebSocketOriginAllowed(origin, h.origins) {
		c.JSON(http.StatusForbidden, models.ErrorResponse(
			models.ErrUnauthorized,
			"Origin is not allowed",
		))
		return
	}

	token := extractWebSocketToken(c)
	if token == "" {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse(
			models.ErrUnauthorized,
			"Missing websocket token",
		))
		return
	}

	if _, err := utils.ValidateToken(token, h.jwtSecret); err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse(
			models.ErrInvalidToken,
			"Invalid or expired websocket token",
		))
		return
	}

	// Upgrade HTTP connection to WebSocket
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("[WSHub] ERROR: Failed to upgrade connection: %v", err)
		return
	}

	// Register the client
	h.register <- conn

	// Read messages from client (for keep-alive)
	go func() {
		defer func() {
			h.unregister <- conn
		}()

		for {
			_, _, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
					log.Printf("[WSHub] ERROR: Unexpected close: %v", err)
				}
				break
			}
		}
	}()

	// Send ping messages to keep connection alive
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}
	}()
}

func extractWebSocketToken(c *gin.Context) string {
	if token := strings.TrimSpace(c.Query("token")); token != "" {
		return token
	}

	authHeader := strings.TrimSpace(c.GetHeader("Authorization"))
	if authHeader == "" {
		return ""
	}

	parts := strings.SplitN(authHeader, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}

	return strings.TrimSpace(parts[1])
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

// BroadcastVPNStatus broadcasts VPN status change
func (h *WSHub) BroadcastVPNStatus(status, profileID string) {
	h.Broadcast("vpn_status", gin.H{
		"status":    status,
		"profileId": profileID,
	})
}

// BroadcastTrafficUpdate broadcasts traffic statistics
func (h *WSHub) BroadcastTrafficUpdate(upload, download, uploadSpeed, downloadSpeed int64) {
	h.Broadcast("traffic_update", gin.H{
		"upload":        upload,
		"download":      download,
		"uploadSpeed":   uploadSpeed,
		"downloadSpeed": downloadSpeed,
	})
}

// BroadcastInstanceStatus broadcasts cloud instance status change
func (h *WSHub) BroadcastInstanceStatus(instanceID, status string) {
	h.Broadcast("instance_status", gin.H{
		"id":     instanceID,
		"status": status,
	})
}
