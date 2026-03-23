package routes

import (
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/api/middleware"
	"privatedeploy/bridge"
	"privatedeploy/bridge/cloud"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// SetupRoutes configures all API routes
func SetupRoutes(router *gin.Engine, db *gorm.DB, cfg *config.Config, wsHub *handlers.WSHub, cloudManager *cloud.Manager) {
	// Middleware
	router.Use(middleware.CORS(cfg))

	// Handlers
	systemHandler := handlers.NewSystemHandler(bridge.Env.AppVersion, "/opt/privatedeploy")
	cloudHandler := handlers.NewCloudHandler(cloudManager)

	profileHandler := handlers.NewProfileHandler(db)
	subscriptionHandler := handlers.NewSubscriptionHandler(db)
	vpnHandler := handlers.NewVPNHandler(
		handlers.NewUnsupportedVPNManager("the standalone API server does not embed a device-level VPN runtime"),
	)

	// Public routes
	public := router.Group("/api/v1")
	{
		// Health check
		public.GET("/health", systemHandler.Health)

		// WebSocket
		public.GET("/ws", wsHub.HandleWS)

		// System
		system := public.Group("/system")
		{
			system.GET("/info", systemHandler.GetInfo)
		}

		// Profiles
		profiles := public.Group("/profiles")
		{
			profiles.GET("/active", profileHandler.GetActive)
			profiles.GET("", profileHandler.List)
			profiles.GET("/:id", profileHandler.Get)
			profiles.GET("/:id/content", profileHandler.GetContent)
			profiles.POST("", profileHandler.Create)
			profiles.PUT("/:id", profileHandler.Update)
			profiles.PUT("/:id/active", profileHandler.SetActive)
			profiles.PUT("/:id/content", profileHandler.UpdateContent)
			profiles.PUT("/:id/subscription", profileHandler.UpdateSubscription)
			profiles.DELETE("/:id", profileHandler.Delete)
		}

		// Subscriptions
		subscriptions := public.Group("/subscriptions")
		{
			subscriptions.GET("", subscriptionHandler.List)
			subscriptions.GET("/:id", subscriptionHandler.Get)
			subscriptions.POST("", subscriptionHandler.Create)
			subscriptions.PUT("/:id", subscriptionHandler.Update)
			subscriptions.DELETE("/:id", subscriptionHandler.Delete)
			subscriptions.PUT("/:id/refresh", subscriptionHandler.Refresh)
		}

		// Cloud
		cloudGroup := public.Group("/cloud")
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

		// VPN
		vpn := public.Group("/vpn")
		{
			vpn.POST("/start", vpnHandler.Start)
			vpn.POST("/stop", vpnHandler.Stop)
			vpn.POST("/restart", vpnHandler.Restart)
			vpn.POST("/stats/reset", vpnHandler.ResetStats)
			vpn.GET("/status", vpnHandler.GetStatus)
			vpn.GET("/stats", vpnHandler.GetStats)
		}
	}
}
