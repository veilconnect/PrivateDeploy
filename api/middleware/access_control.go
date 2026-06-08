package middleware

import (
	"crypto/subtle"
	"net"
	"net/http"
	"privatedeploy/api/config"
	"privatedeploy/api/models"
	"strings"

	"github.com/gin-gonic/gin"
)

// AccessControl restricts the standalone API to localhost by default and
// optionally enforces a shared bearer token for remote or proxied use.
func AccessControl(cfg *config.Config) gin.HandlerFunc {
	allowRemote := cfg.Server.AllowRemote
	authToken := strings.TrimSpace(cfg.Server.AuthToken)

	return func(c *gin.Context) {
		if !allowRemote && !isLoopbackRemoteAddr(c.Request.RemoteAddr) {
			c.AbortWithStatusJSON(
				http.StatusForbidden,
				models.ErrorResponse(models.ErrUnauthorized, "Remote API access is disabled"),
			)
			return
		}

		if authToken != "" && !matchesAuthToken(authToken, c) {
			c.AbortWithStatusJSON(
				http.StatusUnauthorized,
				models.ErrorResponse(models.ErrUnauthorized, "Missing or invalid API token"),
			)
			return
		}

		c.Next()
	}
}

func isLoopbackRemoteAddr(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(strings.TrimSpace(remoteAddr))
	if err != nil {
		host = strings.TrimSpace(remoteAddr)
	}

	host = strings.Trim(host, "[]")
	if host == "" {
		return false
	}

	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func matchesAuthToken(expected string, c *gin.Context) bool {
	if expected == "" {
		return true
	}

	candidates := []string{
		strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer ")),
		strings.TrimSpace(c.GetHeader("X-PrivateDeploy-Token")),
		strings.TrimSpace(c.GetHeader("X-API-Key")),
	}

	expectedBytes := []byte(expected)
	for _, candidate := range candidates {
		if subtle.ConstantTimeCompare([]byte(candidate), expectedBytes) == 1 {
			return true
		}
	}
	return false
}
