package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/models"
	"privatedeploy/api/routes"
	"privatedeploy/api/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func main() {
	log.Println("🚀 Starting PrivateDeploy API Server...")

	// Load configuration
	cfg := config.Load()
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
	wsHub := handlers.NewWSHub()
	log.Println("✅ WebSocket hub initialized")

	// Setup Gin
	if os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
	}
	router := gin.Default()

	// Setup routes
	routes.SetupRoutes(router, db, cfg, wsHub)
	log.Println("✅ Routes configured")

	// Start server
	addr := fmt.Sprintf("%s:%s", cfg.Server.Host, cfg.Server.Port)
	log.Printf("🌐 API Server listening on %s", addr)
	log.Println("📖 API Documentation: /api/v1/health")
	log.Println("---")
	log.Println("Default credentials:")
	log.Println("  Username: admin")
	log.Println("  Password: admin")
	log.Println("---")

	if err := router.Run(addr); err != nil {
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

	// Create default admin user
	hashedPassword, err := utils.HashPassword("admin")
	if err != nil {
		return fmt.Errorf("failed to hash password: %w", err)
	}

	user := models.User{
		Username: "admin",
		Password: hashedPassword,
	}

	if err := db.Create(&user).Error; err != nil {
		return fmt.Errorf("failed to create default user: %w", err)
	}

	log.Println("✅ Default admin user created (username: admin, password: admin)")
	log.Println("⚠️  Please change the default password after first login!")

	return nil
}
