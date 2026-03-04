package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"time"

	"github.com/gin-gonic/gin"
)

// VPNHandler handles VPN-related requests.
type VPNHandler struct {
	vpnManager VPNManager
}

// VPNManager interface for VPN operations.
type VPNManager interface {
	Start(profileID string) error
	Stop() error
	Restart() error
	ResetStats() error
	GetStatus() (*VPNStatus, error)
	GetStats() (*VPNStats, error)
}

// VPNStatus represents VPN connection status.
type VPNStatus struct {
	Status         string    `json:"status"` // connected, disconnected, connecting
	ProfileID      string    `json:"profileId,omitempty"`
	ActiveProfile  string    `json:"active_profile,omitempty"`
	ConnectedAt    time.Time `json:"connectedAt,omitempty"`
	UploadBytes    int64     `json:"upload_bytes"`
	DownloadBytes  int64     `json:"download_bytes"`
	UploadSpeed    int64     `json:"upload_speed"`
	DownloadSpeed  int64     `json:"download_speed"`
	ConnectionTime int64     `json:"connection_time"`
}

// VPNStats represents VPN traffic statistics.
type VPNStats struct {
	UploadBytes    int64 `json:"upload_bytes"`
	DownloadBytes  int64 `json:"download_bytes"`
	UploadSpeed    int64 `json:"upload_speed"`
	DownloadSpeed  int64 `json:"download_speed"`
	ConnectionTime int64 `json:"connection_time"`
}

// NewVPNHandler creates a new VPNHandler.
func NewVPNHandler(vpnManager VPNManager) *VPNHandler {
	return &VPNHandler{
		vpnManager: vpnManager,
	}
}

// Start starts the VPN connection.
func (h *VPNHandler) Start(c *gin.Context) {
	var req struct {
		ProfileID string `json:"profileId"`
	}
	_ = c.ShouldBindJSON(&req)
	if req.ProfileID == "" {
		req.ProfileID = "default"
	}

	log.Printf("[VPNHandler] Starting VPN with profile: %s", req.ProfileID)

	if err := h.vpnManager.Start(req.ProfileID); err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to start VPN: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	status, _ := h.vpnManager.GetStatus()
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status":  "connected",
		"profile": req.ProfileID,
		"vpn":     status,
	}))
}

// Stop stops the VPN connection.
func (h *VPNHandler) Stop(c *gin.Context) {
	log.Printf("[VPNHandler] Stopping VPN")

	if err := h.vpnManager.Stop(); err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to stop VPN: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	status, _ := h.vpnManager.GetStatus()
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "disconnected",
		"vpn":    status,
	}))
}

// Restart restarts the VPN connection.
func (h *VPNHandler) Restart(c *gin.Context) {
	log.Printf("[VPNHandler] Restarting VPN")

	if err := h.vpnManager.Restart(); err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to restart VPN: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	status, _ := h.vpnManager.GetStatus()
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "connected",
		"vpn":    status,
	}))
}

// ResetStats resets VPN traffic stats.
func (h *VPNHandler) ResetStats(c *gin.Context) {
	if err := h.vpnManager.ResetStats(); err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to reset stats: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "stats reset",
	}))
}

// GetStatus returns the current VPN status.
func (h *VPNHandler) GetStatus(c *gin.Context) {
	status, err := h.vpnManager.GetStatus()
	if err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to get status: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	stats, _ := h.vpnManager.GetStats()
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status":         status.Status,
		"profileId":      status.ProfileID,
		"active_profile": status.ActiveProfile,
		"connectedAt":    status.ConnectedAt,
		"stats":          stats,
	}))
}

// GetStats returns VPN traffic statistics.
func (h *VPNHandler) GetStats(c *gin.Context) {
	stats, err := h.vpnManager.GetStats()
	if err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to get stats: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(stats))
}
