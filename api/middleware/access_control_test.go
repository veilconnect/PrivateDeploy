package middleware

import (
	"net/http"
	"net/http/httptest"
	"privatedeploy/api/config"
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
