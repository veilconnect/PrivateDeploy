package routes

import (
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/middleware"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// SetupRoutes configures all API routes
func SetupRoutes(router *gin.Engine, db *gorm.DB, cfg *config.Config) {
	// Middleware
	router.Use(middleware.CORS())

	// Handlers
	authHandler := handlers.NewAuthHandler(db, cfg)
	systemHandler := handlers.NewSystemHandler("1.10.1", "/opt/privatedeploy")

	// Public routes
	public := router.Group("/api/v1")
	{
		// Health check
		public.GET("/health", systemHandler.Health)

		// Auth
		auth := public.Group("/auth")
		{
			auth.POST("/login", authHandler.Login)
		}
	}

	// Protected routes
	protected := router.Group("/api/v1")
	protected.Use(middleware.AuthMiddleware(cfg))
	{
		// Auth
		auth := protected.Group("/auth")
		{
			auth.POST("/refresh", authHandler.Refresh)
		}

		// System
		system := protected.Group("/system")
		{
			system.GET("/info", systemHandler.GetInfo)
		}

		// Cloud (to be implemented)
		// cloud := protected.Group("/cloud")
		// {
		//     cloud.GET("/providers", cloudHandler.ListProviders)
		//     ...
		// }

		// VPN (to be implemented)
		// vpn := protected.Group("/vpn")
		// {
		//     vpn.POST("/start", vpnHandler.Start)
		//     ...
		// }
	}
}
