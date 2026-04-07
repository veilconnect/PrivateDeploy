package middleware

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"privatedeploy/api/config"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// auditMethods lists the HTTP methods that trigger audit logging.
// GET requests are excluded because they do not mutate state.
var auditMethods = map[string]bool{
	"POST":   true,
	"PUT":    true,
	"DELETE": true,
	"PATCH":  true,
}

// auditPrefixes lists the path prefixes whose mutations are security-relevant.
var auditPrefixes = []string{
	"/api/v1/cloud/",
	"/api/v1/profiles",
	"/api/v1/subscriptions",
}

// AuditLog records mutating operations on sensitive endpoints to a log file.
func AuditLog(cfg *config.Config) gin.HandlerFunc {
	if !cfg.Audit.Enabled {
		return func(c *gin.Context) { c.Next() }
	}

	if err := os.MkdirAll(filepath.Dir(cfg.Audit.Path), 0o750); err != nil {
		log.Printf("[AuditLog] WARNING: cannot create log directory: %v", err)
		return func(c *gin.Context) { c.Next() }
	}

	f, err := os.OpenFile(cfg.Audit.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		log.Printf("[AuditLog] WARNING: cannot open audit log %s: %v", cfg.Audit.Path, err)
		return func(c *gin.Context) { c.Next() }
	}

	logger := log.New(f, "", 0)

	return func(c *gin.Context) {
		method := c.Request.Method
		path := c.Request.URL.Path

		if !auditMethods[method] || !isAuditablePath(path) {
			c.Next()
			return
		}

		start := time.Now()

		c.Next()

		status := c.Writer.Status()
		ip := c.ClientIP()
		duration := time.Since(start)

		logger.Printf("%s | %s | %-7s %s | %d | %v",
			time.Now().Format(time.RFC3339),
			ip,
			method,
			path,
			status,
			duration.Round(time.Millisecond),
		)

		if status >= 200 && status < 300 {
			logAction(logger, method, path, ip)
		}
	}
}

func isAuditablePath(path string) bool {
	for _, prefix := range auditPrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func logAction(logger *log.Logger, method, path, ip string) {
	var action string
	switch {
	case method == "POST" && strings.Contains(path, "/cloud/instances"):
		action = "DEPLOY_INSTANCE"
	case method == "DELETE" && strings.Contains(path, "/cloud/instances"):
		action = "DESTROY_INSTANCE"
	case method == "POST" && strings.Contains(path, "/cloud/config"):
		action = "UPDATE_CLOUD_CONFIG"
	case method == "POST" && strings.Contains(path, "/provider/active"):
		action = "SWITCH_PROVIDER"
	case method == "POST" && strings.Contains(path, "/profiles"):
		action = "CREATE_PROFILE"
	case method == "PUT" && strings.Contains(path, "/profiles"):
		action = "UPDATE_PROFILE"
	case method == "DELETE" && strings.Contains(path, "/profiles"):
		action = "DELETE_PROFILE"
	case method == "POST" && strings.Contains(path, "/subscriptions"):
		action = "CREATE_SUBSCRIPTION"
	case method == "DELETE" && strings.Contains(path, "/subscriptions"):
		action = "DELETE_SUBSCRIPTION"
	default:
		return
	}
	logger.Printf("%s | %s | ACTION: %s | path=%s",
		time.Now().Format(time.RFC3339), ip, action, path)
}

// FormatAuditSummary returns a human-readable summary of audit config for startup logging.
func FormatAuditSummary(cfg *config.Config) string {
	if !cfg.Audit.Enabled {
		return "Audit logging disabled"
	}
	return fmt.Sprintf("Audit logging enabled → %s", cfg.Audit.Path)
}
