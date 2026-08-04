package middleware

import (
	"net/http"
	"net/http/httptest"
	"privatedeploy/api/config"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestCORS_PreflightAllowsIdempotencyKey(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.Use(CORS(&config.Config{
		CORS: config.CORSConfig{AllowedOrigins: []string{"http://localhost:5173"}},
	}))
	router.POST("/api/v1/cloud/instances", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/cloud/instances", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	req.Header.Set("Access-Control-Request-Headers", "Idempotency-Key")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected preflight to return 204, got %d", rec.Code)
	}

	allowHeaders := rec.Header().Get("Access-Control-Allow-Headers")
	found := false
	for _, h := range strings.Split(allowHeaders, ",") {
		if strings.EqualFold(strings.TrimSpace(h), "Idempotency-Key") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected Access-Control-Allow-Headers to include Idempotency-Key, got %q", allowHeaders)
	}

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "http://localhost:5173" {
		t.Fatalf("expected allowed origin to be echoed, got %q", got)
	}
}
