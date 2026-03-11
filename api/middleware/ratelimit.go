package middleware

import (
	"net/http"
	"sync"
	"time"

	"privatedeploy/api/models"

	"github.com/gin-gonic/gin"
)

type rateLimiter struct {
	mu       sync.Mutex
	attempts map[string][]time.Time
}

var loginLimiter = &rateLimiter{
	attempts: make(map[string][]time.Time),
}

// LoginRateLimit limits login attempts to maxAttempts per window per IP.
func LoginRateLimit(maxAttempts int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()

		loginLimiter.mu.Lock()
		now := time.Now()
		cutoff := now.Add(-window)

		// Prune old attempts
		valid := loginLimiter.attempts[ip][:0]
		for _, t := range loginLimiter.attempts[ip] {
			if t.After(cutoff) {
				valid = append(valid, t)
			}
		}

		if len(valid) >= maxAttempts {
			loginLimiter.mu.Unlock()
			c.JSON(http.StatusTooManyRequests, models.ErrorResponse(
				"RATE_LIMIT_EXCEEDED",
				"Too many login attempts. Please try again later.",
			))
			c.Abort()
			return
		}

		loginLimiter.attempts[ip] = append(valid, now)
		loginLimiter.mu.Unlock()

		c.Next()
	}
}
