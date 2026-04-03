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
	"privatedeploy/api/routes"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func main() {
	log.Println("🚀 Starting PrivateDeploy API Server...")

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
	router := gin.Default()

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
	if strings.TrimSpace(cfg.Server.AuthToken) != "" {
		log.Println("🔐 API token authentication enabled")
	} else {
		log.Println("🔓 API token authentication disabled")
	}
	log.Printf("🔐 CORS allowed origins: %s", strings.Join(cfg.CORS.AllowedOrigins, ","))

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
