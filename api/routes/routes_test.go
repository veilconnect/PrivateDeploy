package routes

import (
	"context"
	"net/http"
	"net/http/httptest"
	"privatedeploy/api/config"
	"privatedeploy/api/handlers"
	"privatedeploy/bridge/cloud"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestSetupRoutes_RemovesStandaloneVPNEndpoints(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	cfg := &config.Config{
		CORS: config.CORSConfig{
			AllowedOrigins: []string{"http://localhost:5173"},
		},
	}
	wsHub := handlers.NewWSHub(cfg.CORS.AllowedOrigins)
	cloudManager := cloud.NewManager(context.Background(), cloud.NewRegistry())
	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("failed to open in-memory sqlite: %v", err)
	}

	SetupRoutes(router, db, cfg, wsHub, cloudManager)

	healthRecorder := httptest.NewRecorder()
	healthRequest := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	healthRequest.RemoteAddr = "127.0.0.1:54321"
	router.ServeHTTP(healthRecorder, healthRequest)
	if healthRecorder.Code != http.StatusOK {
		t.Fatalf("expected /api/v1/health to remain available, got %d", healthRecorder.Code)
	}

	vpnRecorder := httptest.NewRecorder()
	vpnRequest := httptest.NewRequest(http.MethodGet, "/api/v1/vpn/status", nil)
	vpnRequest.RemoteAddr = "127.0.0.1:54321"
	router.ServeHTTP(vpnRecorder, vpnRequest)
	if vpnRecorder.Code != http.StatusNotFound {
		t.Fatalf("expected /api/v1/vpn/status to be removed, got %d", vpnRecorder.Code)
	}
}
