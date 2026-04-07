package middleware

import (
	"net/http"
	"net/http/httptest"
	"privatedeploy/api/config"
	"testing"

	"github.com/gin-gonic/gin"
)

func newRateLimitRouter(rate float64, burst int) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(RateLimit(&config.Config{
		RateLimit: config.RateLimitConfig{Rate: rate, Burst: burst},
	}))
	r.GET("/api/v1/health", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/test", func(c *gin.Context) { c.Status(http.StatusOK) })
	return r
}

func TestRateLimit_AllowsWithinBurst(t *testing.T) {
	r := newRateLimitRouter(1, 5)

	for i := 0; i < 5; i++ {
		req := httptest.NewRequest(http.MethodGet, "/test", nil)
		req.RemoteAddr = "127.0.0.1:12345"
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: expected 200, got %d", i, rec.Code)
		}
	}
}

func TestRateLimit_BlocksAfterBurst(t *testing.T) {
	r := newRateLimitRouter(0.001, 2) // very slow refill

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodGet, "/test", nil)
		req.RemoteAddr = "10.0.0.1:12345"
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: expected 200, got %d", i, rec.Code)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	req.RemoteAddr = "10.0.0.1:12345"
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 after burst, got %d", rec.Code)
	}
}

func TestRateLimit_HealthEndpointExempt(t *testing.T) {
	r := newRateLimitRouter(0.001, 1)

	// Exhaust the bucket
	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	req.RemoteAddr = "10.0.0.2:12345"
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	// Health should still pass
	for i := 0; i < 5; i++ {
		req = httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
		req.RemoteAddr = "10.0.0.2:12345"
		rec = httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("health request %d: expected 200, got %d", i, rec.Code)
		}
	}
}

func TestRateLimit_DisabledWhenRateZero(t *testing.T) {
	r := newRateLimitRouter(0, 0)

	for i := 0; i < 100; i++ {
		req := httptest.NewRequest(http.MethodGet, "/test", nil)
		req.RemoteAddr = "10.0.0.3:12345"
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: expected 200 when disabled, got %d", i, rec.Code)
		}
	}
}

func TestRateLimit_IsolatesClients(t *testing.T) {
	r := newRateLimitRouter(0.001, 1)

	// Client A exhausts bucket
	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	req.RemoteAddr = "10.0.0.10:12345"
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	// Client B should still work
	req = httptest.NewRequest(http.MethodGet, "/test", nil)
	req.RemoteAddr = "10.0.0.11:12345"
	rec = httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("client B should not be affected by client A, got %d", rec.Code)
	}
}
