package routes

import (
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/middleware"
	"privatedeploy/bridge/cloud"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// SetupRoutes configures all API routes
func SetupRoutes(router *gin.Engine, db *gorm.DB, cfg *config.Config, wsHub *handlers.WSHub, cloudManager *cloud.Manager) {
	// Middleware
	router.Use(middleware.CORS(cfg))

	// Handlers
	authHandler := handlers.NewAuthHandler(db, cfg)
	systemHandler := handlers.NewSystemHandler("1.10.1", "/opt/privatedeploy")
	cloudHandler := handlers.NewCloudHandler(cloudManager)

	// Note: These require actual implementations, using nil for now
	// In production, you would inject real VPNManager instances
	profileHandler := handlers.NewProfileHandler(db)
	subscriptionHandler := handlers.NewSubscriptionHandler(db)

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

		// WebSocket (requires valid token)
		public.GET("/ws", wsHub.HandleWS)
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

		// Profiles
		profiles := protected.Group("/profiles")
		{
			profiles.GET("", profileHandler.List)
			profiles.GET("/:id", profileHandler.Get)
			profiles.POST("", profileHandler.Create)
			profiles.PUT("/:id", profileHandler.Update)
			profiles.DELETE("/:id", profileHandler.Delete)
		}

		// Subscriptions
		subscriptions := protected.Group("/subscriptions")
		{
			subscriptions.GET("", subscriptionHandler.List)
			subscriptions.GET("/:id", subscriptionHandler.Get)
			subscriptions.POST("", subscriptionHandler.Create)
			subscriptions.PUT("/:id", subscriptionHandler.Update)
			subscriptions.DELETE("/:id", subscriptionHandler.Delete)
			subscriptions.PUT("/:id/refresh", subscriptionHandler.Refresh)
		}

		// Cloud
		cloudGroup := protected.Group("/cloud")
		{
			cloudGroup.GET("/providers", cloudHandler.ListProviders)
			cloudGroup.GET("/provider/active", cloudHandler.GetActiveProvider)
			cloudGroup.POST("/provider/active", cloudHandler.SetActiveProvider)
			cloudGroup.GET("/config", cloudHandler.GetConfig)
			cloudGroup.POST("/config", cloudHandler.SaveConfig)
			cloudGroup.GET("/instances", cloudHandler.ListInstances)
			cloudGroup.POST("/instances", cloudHandler.CreateInstance)
			cloudGroup.DELETE("/instances/:id", cloudHandler.DestroyInstance)
			cloudGroup.GET("/regions", cloudHandler.ListRegions)
			cloudGroup.GET("/plans", cloudHandler.ListPlans)
			cloudGroup.GET("/availability", cloudHandler.ListAvailability)
		}

		// VPN (commented out until VPNManager is properly integrated)
		// vpn := protected.Group("/vpn")
		// {
		//     vpn.POST("/start", vpnHandler.Start)
		//     vpn.POST("/stop", vpnHandler.Stop)
		//     vpn.GET("/status", vpnHandler.GetStatus)
		//     vpn.GET("/stats", vpnHandler.GetStats)
		// }
	}
}
