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

// tokenExemptPaths are read-only, non-sensitive endpoints that stay reachable
// without a token so health probes and dashboards keep working under the
// default-on token policy. They remain subject to the loopback restriction.
var tokenExemptPaths = map[string]bool{
	"/api/v1/health":       true,
	"/api/v1/version":      true,
	"/api/v1/openapi.yaml": true,
}

// wsQueryTokenPath is the only path allowed to authenticate via a `token`
// query parameter. The browser WebSocket API cannot attach custom headers,
// so the frontend (frontend/src/utils/websockets.ts) passes the shared token
// as `?token=...` when dialing the websocket endpoint.
//
// SECURITY: the query token must never be written to any log. Nothing in
// this package logs URLs; note that gin's default access logger (gin.Default
// in api/main.go) does log path+query and should be replaced/redacted there.
const wsQueryTokenPath = "/api/v1/ws"

// AccessControl restricts the standalone API to localhost by default and
// enforces a shared bearer token for everything beyond the health/version
// probes (token auth is on by default; see config.Load).
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

		if authToken != "" && !tokenExemptPaths[c.Request.URL.Path] && !matchesAuthToken(authToken, c) {
			c.AbortWithStatusJSON(
				http.StatusUnauthorized,
				models.ErrorResponse(models.ErrUnauthorized, "Missing or invalid API token"),
			)
			return
		}

		// The WebSocket token has served its only purpose. Remove it from both
		// URL.RawQuery and RequestURI before downstream handlers/recovery run so
		// even a panic or broken-pipe request dump cannot write it to logs.
		if c.Request.URL.Path == wsQueryTokenPath && c.Query("token") != "" {
			query := c.Request.URL.Query()
			query.Del("token")
			c.Request.URL.RawQuery = query.Encode()
			c.Request.RequestURI = c.Request.URL.RequestURI()
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

	// Browser WebSocket clients cannot set custom headers, so accept a
	// `token` query parameter on the websocket endpoint only. Do not log it.
	if c.Request.URL.Path == wsQueryTokenPath {
		if queryToken := strings.TrimSpace(c.Query("token")); queryToken != "" {
			candidates = append(candidates, queryToken)
		}
	}

	expectedBytes := []byte(expected)
	for _, candidate := range candidates {
		if subtle.ConstantTimeCompare([]byte(candidate), expectedBytes) == 1 {
			return true
		}
	}
	return false
}
