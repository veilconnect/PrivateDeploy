package middleware

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"privatedeploy/api/config"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestAuditLog_LogsMutatingCloudOperations(t *testing.T) {
	gin.SetMode(gin.TestMode)

	dir := t.TempDir()
	logPath := filepath.Join(dir, "audit.log")

	cfg := &config.Config{
		Audit: config.AuditConfig{Enabled: true, Path: logPath},
	}

	r := gin.New()
	r.Use(AuditLog(cfg))
	r.POST("/api/v1/cloud/instances", func(c *gin.Context) { c.Status(http.StatusCreated) })
	r.GET("/api/v1/cloud/instances", func(c *gin.Context) { c.Status(http.StatusOK) })

	// POST should be logged
	req := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/instances", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	// GET should NOT be logged
	req = httptest.NewRequest(http.MethodGet, "/api/v1/cloud/instances", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rec = httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("failed to read audit log: %v", err)
	}

	content := string(data)
	if !strings.Contains(content, "POST") {
		t.Fatal("audit log should contain POST entry")
	}
	if strings.Contains(content, "GET") {
		t.Fatal("audit log should not contain GET entry")
	}
	if !strings.Contains(content, "DEPLOY_INSTANCE") {
		t.Fatal("audit log should contain DEPLOY_INSTANCE action")
	}
}

func TestAuditLog_SkipsNonAuditablePaths(t *testing.T) {
	gin.SetMode(gin.TestMode)

	dir := t.TempDir()
	logPath := filepath.Join(dir, "audit.log")

	cfg := &config.Config{
		Audit: config.AuditConfig{Enabled: true, Path: logPath},
	}

	r := gin.New()
	r.Use(AuditLog(cfg))
	r.POST("/api/v1/system/info", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/system/info", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	data, _ := os.ReadFile(logPath)
	if len(data) > 0 {
		t.Fatal("non-auditable path should not produce log entries")
	}
}

func TestAuditLog_DisabledByDefault(t *testing.T) {
	gin.SetMode(gin.TestMode)

	r := gin.New()
	r.Use(AuditLog(&config.Config{}))
	r.POST("/api/v1/cloud/instances", func(c *gin.Context) { c.Status(http.StatusCreated) })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/instances", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", rec.Code)
	}
}
