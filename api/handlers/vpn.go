package handlers

import (
	"errors"
	"log"
	"net/http"
	"privatedeploy/api/models"

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
	GetStatus() (*models.VPNStatus, error)
	GetStats() (*models.VPNStats, error)
}

// NewVPNHandler creates a new VPNHandler.
func NewVPNHandler(vpnManager VPNManager) *VPNHandler {
	return &VPNHandler{
		vpnManager: vpnManager,
	}
}

func writeVPNError(c *gin.Context, err error) {
	statusCode := http.StatusInternalServerError
	if errors.Is(err, ErrVPNUnsupported) {
		statusCode = http.StatusNotImplemented
	}

	c.JSON(statusCode, models.ErrorResponse(
		models.ErrVPNError,
		err.Error(),
	))
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
		writeVPNError(c, err)
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
		writeVPNError(c, err)
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
		writeVPNError(c, err)
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
		writeVPNError(c, err)
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
		writeVPNError(c, err)
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
		writeVPNError(c, err)
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(stats))
}
