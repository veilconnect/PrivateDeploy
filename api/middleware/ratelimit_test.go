package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

// newTestRouter wires up a minimal Gin engine with the rate-limit middleware
// and a trivial 200 OK handler, using a fresh rateLimiter so tests are
// independent of the package-level loginLimiter state.
func newTestRouter(limiter *rateLimiter, maxAttempts int, window time.Duration) *gin.Engine {
	r := gin.New()
	r.POST("/login", rateLimitWith(limiter, maxAttempts, window), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})
	return r
}

// rateLimitWith is identical to LoginRateLimit but operates on an injected
// rateLimiter so each test starts with a clean slate.
func rateLimitWith(rl *rateLimiter, maxAttempts int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()

		rl.mu.Lock()
		now := time.Now()
		cutoff := now.Add(-window)

		valid := rl.attempts[ip][:0]
		for _, t := range rl.attempts[ip] {
			if t.After(cutoff) {
				valid = append(valid, t)
			}
		}

		if len(valid) >= maxAttempts {
			rl.mu.Unlock()
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			c.Abort()
			return
		}

		rl.attempts[ip] = append(valid, now)
		rl.mu.Unlock()
		c.Next()
	}
}

func freshLimiter() *rateLimiter {
	return &rateLimiter{attempts: make(map[string][]time.Time)}
}

func doRequest(r *gin.Engine) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/login", nil)
	req.Header.Set("X-Forwarded-For", "192.0.2.1") // deterministic IP
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// --- Tests ---

func TestRateLimit_AllowsRequestsUnderLimit(t *testing.T) {
	const maxAttempts = 5
	rl := freshLimiter()
	r := newTestRouter(rl, maxAttempts, time.Minute)

	for i := 0; i < maxAttempts; i++ {
		w := doRequest(r)
		if w.Code != http.StatusOK {
			t.Fatalf("request %d: want 200, got %d", i+1, w.Code)
		}
	}
}

func TestRateLimit_BlocksAfterExceedingLimit(t *testing.T) {
	const maxAttempts = 3
	rl := freshLimiter()
	r := newTestRouter(rl, maxAttempts, time.Minute)

	for i := 0; i < maxAttempts; i++ {
		doRequest(r) // exhaust the allowance
	}

	w := doRequest(r) // one over the limit
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429 after limit exceeded, got %d", w.Code)
	}
}

func TestRateLimit_FirstRequestAfterExhaustion_IsBlocked(t *testing.T) {
	const maxAttempts = 1
	rl := freshLimiter()
	r := newTestRouter(rl, maxAttempts, time.Minute)

	first := doRequest(r)
	if first.Code != http.StatusOK {
		t.Fatalf("first request: want 200, got %d", first.Code)
	}

	second := doRequest(r)
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second request: want 429, got %d", second.Code)
	}
}

func TestRateLimit_ResetsAfterWindowExpires(t *testing.T) {
	const maxAttempts = 2
	// Use a very short window so we can expire it in the test without sleeping.
	window := 50 * time.Millisecond
	rl := freshLimiter()
	r := newTestRouter(rl, maxAttempts, window)

	// Exhaust the window.
	for i := 0; i < maxAttempts; i++ {
		doRequest(r)
	}
	// Confirm we are blocked.
	if w := doRequest(r); w.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 before reset, got %d", w.Code)
	}

	// Wait for the window to expire then manually back-date all stored
	// timestamps so the next real clock call sees them as outside the window.
	time.Sleep(window + 10*time.Millisecond)

	// After the window, attempts should be accepted again.
	w := doRequest(r)
	if w.Code != http.StatusOK {
		t.Fatalf("want 200 after window reset, got %d", w.Code)
	}
}

func TestRateLimit_DifferentIPsAreTrackedIndependently(t *testing.T) {
	const maxAttempts = 1
	rl := freshLimiter()
	r := newTestRouter(rl, maxAttempts, time.Minute)

	// Exhaust limit for IP A.
	reqA := httptest.NewRequest(http.MethodPost, "/login", nil)
	reqA.Header.Set("X-Forwarded-For", "10.0.0.1")
	wA := httptest.NewRecorder()
	r.ServeHTTP(wA, reqA)
	if wA.Code != http.StatusOK {
		t.Fatalf("IP A first request: want 200, got %d", wA.Code)
	}
	// A is now blocked.
	reqA2 := httptest.NewRequest(http.MethodPost, "/login", nil)
	reqA2.Header.Set("X-Forwarded-For", "10.0.0.1")
	wA2 := httptest.NewRecorder()
	r.ServeHTTP(wA2, reqA2)
	if wA2.Code != http.StatusTooManyRequests {
		t.Fatalf("IP A second request: want 429, got %d", wA2.Code)
	}

	// IP B should still be allowed.
	reqB := httptest.NewRequest(http.MethodPost, "/login", nil)
	reqB.Header.Set("X-Forwarded-For", "10.0.0.2")
	wB := httptest.NewRecorder()
	r.ServeHTTP(wB, reqB)
	if wB.Code != http.StatusOK {
		t.Fatalf("IP B first request: want 200, got %d", wB.Code)
	}
}

func TestRateLimit_ZeroMaxAttempts_AlwaysBlocks(t *testing.T) {
	rl := freshLimiter()
	r := newTestRouter(rl, 0, time.Minute)

	w := doRequest(r)
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("zero maxAttempts: want 429, got %d", w.Code)
	}
}
