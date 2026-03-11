package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/models"
	"privatedeploy/api/routes"
	"privatedeploy/api/utils"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

const insecureJWTSecret = "privatedeploy-secret-change-me"

func main() {
	log.Println("🚀 Starting PrivateDeploy API Server...")

	// Load configuration
	cfg := config.Load()
	if err := ensureJWTSecret(cfg); err != nil {
		log.Fatalf("❌ Security bootstrap failed: %v", err)
	}
	log.Printf("📋 Configuration loaded (Port: %s)", cfg.Server.Port)

	// Setup database
	db, err := setupDatabase(cfg.Database.Path)
	if err != nil {
		log.Fatalf("❌ Failed to setup database: %v", err)
	}
	log.Println("✅ Database initialized")

	// Initialize default user
	if err := initializeDefaultUser(db); err != nil {
		log.Fatalf("❌ Failed to initialize default user: %v", err)
	}

	// Setup WebSocket hub
	wsHub := handlers.NewWSHub(cfg.JWT.Secret, cfg.CORS.AllowedOrigins)
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
	if err := os.MkdirAll(dbDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	// Open database
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Auto migrate
	if err := db.AutoMigrate(&models.User{}); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return db, nil
}

// initializeDefaultUser creates a default admin user if it doesn't exist
func initializeDefaultUser(db *gorm.DB) error {
	var count int64
	if err := db.Model(&models.User{}).Count(&count).Error; err != nil {
		return fmt.Errorf("failed to count users: %w", err)
	}

	// If users exist, skip initialization
	if count > 0 {
		log.Println("ℹ️  Users already exist, skipping default user creation")
		return nil
	}

	username := strings.TrimSpace(os.Getenv("INITIAL_ADMIN_USERNAME"))
	if username == "" {
		username = "admin"
	}

	password := strings.TrimSpace(os.Getenv("INITIAL_ADMIN_PASSWORD"))
	if password == "" {
		if isProductionMode() {
			return fmt.Errorf("INITIAL_ADMIN_PASSWORD is required in production when bootstrapping the first admin user")
		}
		password = generateSecureToken(20)
		log.Printf("⚠️  INITIAL_ADMIN_PASSWORD not set, generated one-time password for %q: %s", username, password)
		log.Println("⚠️  Set INITIAL_ADMIN_PASSWORD in environment to avoid random bootstrap credentials.")
	}

	hashedPassword, err := utils.HashPassword(password)
	if err != nil {
		return fmt.Errorf("failed to hash password: %w", err)
	}

	user := models.User{
		Username: username,
		Password: hashedPassword,
	}

	if err := db.Create(&user).Error; err != nil {
		return fmt.Errorf("failed to create default user: %w", err)
	}

	log.Printf("✅ Bootstrap user created: %s", username)
	log.Println("⚠️  Change this password immediately after first login.")

	return nil
}

func ensureJWTSecret(cfg *config.Config) error {
	secret := strings.TrimSpace(cfg.JWT.Secret)
	if secret != "" && secret != insecureJWTSecret {
		return nil
	}

	if isProductionMode() {
		return fmt.Errorf("JWT_SECRET is required in production and cannot use the default insecure value")
	}

	cfg.JWT.Secret = generateSecureToken(48)
	log.Println("⚠️  JWT_SECRET is missing or insecure. Generated an in-memory secret for this process.")
	log.Println("⚠️  Set JWT_SECRET in environment for stable tokens across restarts.")
	return nil
}

func generateSecureToken(length int) string {
	if length <= 0 {
		return ""
	}

	// RawURLEncoding expands 3 bytes into 4 chars. Allocate enough entropy for requested output length.
	raw := make([]byte, (length*3)/4+4)
	if _, err := rand.Read(raw); err != nil {
		panic(fmt.Errorf("failed to generate secure random token: %w", err))
	}

	token := base64.RawURLEncoding.EncodeToString(raw)
	if len(token) < length {
		return token
	}
	return token[:length]
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

func isProductionMode() bool {
	for _, key := range []string{"API_ENV", "APP_ENV"} {
		value := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
		if value == "production" || value == "prod" {
			return true
		}
	}
	return false
}
