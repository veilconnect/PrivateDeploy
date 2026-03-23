package middleware

import (
	"net/http"
	"privatedeploy/api/config"
	"slices"

	"github.com/gin-gonic/gin"
)

// CORS applies a simple allowlist-based CORS policy for local UI clients.
func CORS(cfg *config.Config) gin.HandlerFunc {
	allowedOrigins := append([]string(nil), cfg.CORS.AllowedOrigins...)

	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" && isAllowedOrigin(allowedOrigins, origin) {
			headers := c.Writer.Header()
			headers.Set("Access-Control-Allow-Origin", origin)
			headers.Set("Vary", "Origin")
			headers.Set("Access-Control-Allow-Credentials", "true")
		}

		headers := c.Writer.Header()
		headers.Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		headers.Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, accept, origin, Cache-Control, X-Requested-With")

		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}

func isAllowedOrigin(allowedOrigins []string, origin string) bool {
	return slices.Contains(allowedOrigins, origin)
}
