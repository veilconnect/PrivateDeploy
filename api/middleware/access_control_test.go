package middleware

import (
	"net/http"
	"net/http/httptest"
	"privatedeploy/api/config"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestAccessControl_AllowsLoopbackRequestsByDefault(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected loopback request to pass, got %d", rec.Code)
	}
}

func TestAccessControl_BlocksRemoteRequestsWhenDisabled(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "203.0.113.10:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected remote request to be blocked, got %d", rec.Code)
	}
}

func TestAccessControl_AllowsRemoteWhenConfigured(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AllowRemote: true},
	}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "203.0.113.10:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected remote request to pass, got %d", rec.Code)
	}
}

func TestAccessControl_RequiresConfiguredToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected missing token to be rejected, got %d", rec.Code)
	}
}

func TestAccessControl_RejectsWrongToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Authorization", "Bearer wrong-secret")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected wrong token to be rejected, got %d", rec.Code)
	}
}

func TestAccessControl_HealthAndVersionExemptFromToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	for _, path := range []string{"/api/v1/health", "/api/v1/version", "/api/v1/openapi.yaml"} {
		router.GET(path, func(c *gin.Context) { c.Status(http.StatusOK) })
	}

	for _, path := range []string{"/api/v1/health", "/api/v1/version", "/api/v1/openapi.yaml"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.RemoteAddr = "127.0.0.1:54321"
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("expected %s to be reachable without a token, got %d", path, rec.Code)
		}
	}
}

func TestAccessControl_TokenExemptPathsStillLoopbackRestricted(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	router.GET("/api/v1/health", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	req.RemoteAddr = "203.0.113.10:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected remote health probe to stay blocked, got %d", rec.Code)
	}
}

// newTokenRouter builds a router with AccessControl enforcing the given token
// and OK handlers on the websocket path plus a generic /ping route.
func newTokenRouter(token string) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: token},
	}))
	router.GET(wsQueryTokenPath, func(c *gin.Context) { c.Status(http.StatusOK) })
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })
	return router
}

func TestAccessControl_WSAcceptsCorrectQueryToken(t *testing.T) {
	router := newTokenRouter("shared-secret")

	req := httptest.NewRequest(http.MethodGet, wsQueryTokenPath+"?token=shared-secret", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected correct query token on %s to pass, got %d", wsQueryTokenPath, rec.Code)
	}
}

func TestAccessControl_WSRemovesQueryTokenBeforeHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	router.GET(wsQueryTokenPath, func(c *gin.Context) {
		if strings.Contains(c.Request.URL.RawQuery, "token") {
			t.Fatalf("token remained in RawQuery: %q", c.Request.URL.RawQuery)
		}
		if strings.Contains(c.Request.RequestURI, "token") {
			t.Fatalf("token remained in RequestURI: %q", c.Request.RequestURI)
		}
		if got := c.Query("channel"); got != "status" {
			t.Fatalf("non-secret query was not preserved: %q", got)
		}
		c.Status(http.StatusOK)
	})

	req := httptest.NewRequest(http.MethodGet, wsQueryTokenPath+"?channel=status&token=shared-secret", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected websocket request to pass, got %d", rec.Code)
	}
}

func TestAccessControl_WSRejectsWrongQueryToken(t *testing.T) {
	router := newTokenRouter("shared-secret")

	for _, query := range []string{"?token=wrong-secret", "?token=", ""} {
		req := httptest.NewRequest(http.MethodGet, wsQueryTokenPath+query, nil)
		req.RemoteAddr = "127.0.0.1:54321"
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)

		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("expected query %q on %s to be rejected, got %d", query, wsQueryTokenPath, rec.Code)
		}
	}
}

func TestAccessControl_QueryTokenRejectedOnNonWSPaths(t *testing.T) {
	router := newTokenRouter("shared-secret")

	req := httptest.NewRequest(http.MethodGet, "/ping?token=shared-secret", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected query token on non-ws path to be rejected, got %d", rec.Code)
	}
}

func TestAccessControl_WSStillAcceptsHeaderToken(t *testing.T) {
	router := newTokenRouter("shared-secret")

	req := httptest.NewRequest(http.MethodGet, wsQueryTokenPath, nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Authorization", "Bearer shared-secret")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected header token on %s to pass, got %d", wsQueryTokenPath, rec.Code)
	}
}

func TestAccessControl_AcceptsBearerToken(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(AccessControl(&config.Config{
		Server: config.ServerConfig{AuthToken: "shared-secret"},
	}))
	router.GET("/ping", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Authorization", "Bearer shared-secret")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected bearer token to pass, got %d", rec.Code)
	}
}
