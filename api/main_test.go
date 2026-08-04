package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestSetupDatabase_CreatesParentDirectoryAndFile(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "nested", "data", "privatedeploy.db")

	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("extract sql DB: %v", err)
	}
	defer sqlDB.Close()

	if err := db.Exec("SELECT 1").Error; err != nil {
		t.Fatalf("ping sqlite database: %v", err)
	}

	if _, err := os.Stat(filepath.Dir(dbPath)); err != nil {
		t.Fatalf("expected database directory to exist: %v", err)
	}
	if _, err := os.Stat(dbPath); err != nil {
		t.Fatalf("expected database file to exist: %v", err)
	}
}

func TestSetupDatabase_CanReuseExistingDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")

	firstDB, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("first setup database: %v", err)
	}
	firstSQLDB, err := firstDB.DB()
	if err != nil {
		t.Fatalf("first sql DB: %v", err)
	}
	firstSQLDB.Close()

	secondDB, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("second setup database: %v", err)
	}
	secondSQLDB, err := secondDB.DB()
	if err != nil {
		t.Fatalf("second sql DB: %v", err)
	}
	defer secondSQLDB.Close()

	if err := secondDB.Exec("SELECT 1").Error; err != nil {
		t.Fatalf("query reopened database: %v", err)
	}
}

func TestSetupDatabase_LimitsSQLiteToSingleConnection(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")

	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("extract sql DB: %v", err)
	}
	defer sqlDB.Close()

	if got := sqlDB.Stats().MaxOpenConnections; got != 1 {
		t.Fatalf("expected SQLite to be limited to 1 open connection, got %d", got)
	}
}

func TestRequestLogFormatterOmitsQueryString(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/ws?token=super-secret-query-token", nil)

	line := requestLogFormatter(gin.LogFormatterParams{
		Request:    req,
		TimeStamp:  time.Now(),
		StatusCode: http.StatusSwitchingProtocols,
		Latency:    5 * time.Millisecond,
		ClientIP:   "127.0.0.1",
		Method:     http.MethodGet,
		// gin populates Path with the raw query appended — exactly what the
		// formatter must not echo.
		Path: "/api/v1/ws?token=super-secret-query-token",
	})

	if strings.Contains(line, "super-secret-query-token") {
		t.Fatalf("access log leaked the query token: %q", line)
	}
	if strings.Contains(line, "?") {
		t.Fatalf("access log must not contain any query string: %q", line)
	}
	if !strings.Contains(line, "/api/v1/ws") {
		t.Fatalf("access log lost the request path: %q", line)
	}
}

func TestConfigureClientIPTrustRejectsSpoofedForwardingHeaders(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	if err := configureClientIPTrust(router); err != nil {
		t.Fatalf("configure client IP trust: %v", err)
	}
	router.GET("/ip", func(c *gin.Context) {
		c.String(http.StatusOK, c.ClientIP())
	})

	req := httptest.NewRequest(http.MethodGet, "/ip", nil)
	req.RemoteAddr = "198.51.100.24:43120"
	req.Header.Set("X-Forwarded-For", "203.0.113.99")
	req.Header.Set("X-Real-IP", "203.0.113.100")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("unexpected response status: %d", recorder.Code)
	}
	if got := strings.TrimSpace(recorder.Body.String()); got != "198.51.100.24" {
		t.Fatalf("forwarding header spoof changed client IP: got %q", got)
	}
}
