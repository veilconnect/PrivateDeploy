package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/middleware"
	"privatedeploy/api/routes"
	"privatedeploy/bridge"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func main() {
	log.Printf("🚀 Starting PrivateDeploy API Server %s...", bridge.AppVersion)

	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("❌ Failed to load configuration: %v", err)
	}
	log.Printf("📋 Configuration loaded (Port: %s)", cfg.Server.Port)

	// Setup database
	db, err := setupDatabase(cfg.Database.Path)
	if err != nil {
		log.Fatalf("❌ Failed to setup database: %v", err)
	}
	log.Println("✅ Database initialized")

	// Setup WebSocket hub
	wsHub := handlers.NewWSHub(cfg.CORS.AllowedOrigins)
	log.Println("✅ WebSocket hub initialized")

	// Setup Cloud Manager
	cloudManager := initializeCloudManager()
	log.Println("✅ Cloud manager initialized")

	// Setup Gin
	if os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
	}
	// gin.Default()'s logger would print the full request URL including the
	// query string; /api/v1/ws accepts ?token=... (browser WebSocket clients
	// cannot set headers), so the access log must never contain queries.
	router := gin.New()
	// Gin otherwise trusts forwarding headers from every proxy by default.
	// This API has no configured reverse-proxy trust boundary, so accepting a
	// caller-controlled X-Forwarded-For would let remote clients evade the
	// per-IP limiter/audit identity and create an unbounded stream of visitor
	// keys. Use the socket peer until an explicit trusted-CIDR setting exists.
	if err := configureClientIPTrust(router); err != nil {
		log.Fatalf("❌ Failed to disable untrusted proxy headers: %v", err)
	}
	router.Use(gin.LoggerWithFormatter(requestLogFormatter), gin.Recovery())

	// Distinguish 405 (wrong method) from 404 (no such path) so clients
	// can tell whether to fix their verb or fix their URL. Without this,
	// gin returns 404 for both cases which masks programming mistakes.
	router.HandleMethodNotAllowed = true
	router.NoMethod(func(c *gin.Context) {
		c.JSON(http.StatusMethodNotAllowed, gin.H{
			"success": false,
			"error": gin.H{
				"code":    "METHOD_NOT_ALLOWED",
				"message": "Method " + c.Request.Method + " not allowed for " + c.Request.URL.Path,
			},
		})
	})

	// Setup routes
	routes.SetupRoutes(router, db, cfg, wsHub, cloudManager)
	log.Println("✅ Routes configured")

	// Start server
	addr := fmt.Sprintf("%s:%s", cfg.Server.Host, cfg.Server.Port)
	log.Printf("🌐 API Server listening on %s", addr)
	log.Println("📖 API Documentation: /api/v1/health")
	if cfg.Server.AllowRemote {
		log.Println("🌍 Remote API access enabled")
	} else {
		log.Println("🏠 Remote API access disabled; localhost clients only")
	}
	switch cfg.Server.AuthTokenSource {
	case config.AuthTokenSourceGenerated:
		// Log only the path — the token value must never reach the logs.
		log.Printf("🔐 API token authentication enabled (auto-generated token file: %s)", cfg.Server.AuthTokenPath)
	case config.AuthTokenSourceDisabled:
		log.Println("🔓 API token authentication DISABLED via API_ALLOW_UNAUTHENTICATED=true (loopback-only)")
	default:
		log.Println("🔐 API token authentication enabled")
	}
	log.Printf("🔐 CORS allowed origins: %s", strings.Join(cfg.CORS.AllowedOrigins, ","))
	if cfg.RateLimit.Rate > 0 {
		log.Printf("🚦 Rate limiting: %.0f req/s, burst %d", cfg.RateLimit.Rate, cfg.RateLimit.Burst)
	}
	log.Printf("📝 %s", middleware.FormatAuditSummary(cfg))

	srv := &http.Server{
		Addr:              addr,
		Handler:           router,
		ReadTimeout:       cfg.Server.ReadTimeout,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      cfg.Server.WriteTimeout,
		IdleTimeout:       60 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("❌ Failed to start server: %v", err)
	}
}

func configureClientIPTrust(router *gin.Engine) error {
	return router.SetTrustedProxies(nil)
}

// requestLogFormatter renders one access-log line. It deliberately logs only
// URL.Path — never the query string — because query parameters can carry
// credentials (the WebSocket endpoint authenticates via ?token=...). Do not
// switch this back to param.Path: gin appends the raw query to it.
func requestLogFormatter(param gin.LogFormatterParams) string {
	path := ""
	if param.Request != nil && param.Request.URL != nil {
		path = param.Request.URL.Path
	}
	return fmt.Sprintf("[GIN] %s | %3d | %13v | %15s | %-7s %s\n",
		param.TimeStamp.Format("2006/01/02 - 15:04:05"),
		param.StatusCode,
		param.Latency,
		param.ClientIP,
		param.Method,
		path,
	)
}

// setupDatabase initializes the database
func setupDatabase(dbPath string) (*gorm.DB, error) {
	// Ensure data directory exists
	dbDir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dbDir, 0o700); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	// Open database
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Background cloud operations write concurrently with request handlers;
	// without a busy timeout SQLite fails those writes with "database is locked".
	if err := db.Exec("PRAGMA busy_timeout = 5000").Error; err != nil {
		return nil, fmt.Errorf("failed to set sqlite busy timeout: %w", err)
	}

	// SQLite allows only one writer at a time; funneling all gorm access
	// through a single connection serializes writers in Go instead of racing
	// for the file lock (busy_timeout stays as the safety net for external
	// processes touching the same file).
	sqlDB, err := db.DB()
	if err != nil {
		return nil, fmt.Errorf("failed to access sql database handle: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)

	return db, nil
}

// initializeCloudManager sets up the cloud provider manager
func initializeCloudManager() *cloud.Manager {
	// Create manager with shared default provider registry
	registry := defaults.Registry()
	manager := cloud.NewManager(context.Background(), registry)

	// Set Vultr as the default active provider
	if err := manager.SetActiveProvider("vultr"); err != nil {
		log.Printf("⚠️  Warning: Failed to set default provider: %v", err)
	}

	log.Printf("📦 Registered cloud providers: %v", registry.List())
	return manager
}
