package middleware

import (
	"net"
	"net/http"
	"privatedeploy/api/config"
	"privatedeploy/api/models"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type visitor struct {
	tokens   float64
	lastSeen time.Time
}

// RateLimit enforces per-IP token-bucket rate limiting.
// Health and WebSocket endpoints are exempt.
func RateLimit(cfg *config.Config) gin.HandlerFunc {
	rate := cfg.RateLimit.Rate
	burst := cfg.RateLimit.Burst

	if rate <= 0 {
		return func(c *gin.Context) { c.Next() }
	}

	var mu sync.Mutex
	visitors := make(map[string]*visitor)

	// Background cleanup of stale entries every minute.
	go func() {
		for {
			time.Sleep(time.Minute)
			mu.Lock()
			for ip, v := range visitors {
				if time.Since(v.lastSeen) > 5*time.Minute {
					delete(visitors, ip)
				}
			}
			mu.Unlock()
		}
	}()

	return func(c *gin.Context) {
		path := c.Request.URL.Path
		if path == "/api/v1/health" || path == "/api/v1/ws" {
			c.Next()
			return
		}

		ip := clientIP(c)

		mu.Lock()
		v, exists := visitors[ip]
		if !exists {
			v = &visitor{tokens: float64(burst)}
			visitors[ip] = v
		}

		elapsed := time.Since(v.lastSeen).Seconds()
		v.lastSeen = time.Now()
		v.tokens += elapsed * rate
		if v.tokens > float64(burst) {
			v.tokens = float64(burst)
		}

		if v.tokens < 1 {
			mu.Unlock()
			c.AbortWithStatusJSON(
				http.StatusTooManyRequests,
				models.ErrorResponse("RATE_LIMITED", "Too many requests, please try again later"),
			)
			return
		}

		v.tokens--
		mu.Unlock()

		c.Next()
	}
}

func clientIP(c *gin.Context) string {
	ip := c.ClientIP()
	if ip == "" {
		host, _, err := net.SplitHostPort(strings.TrimSpace(c.Request.RemoteAddr))
		if err != nil {
			return c.Request.RemoteAddr
		}
		return host
	}
	return ip
}
