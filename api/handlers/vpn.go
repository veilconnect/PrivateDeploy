package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"time"

	"github.com/gin-gonic/gin"
)

// VPNHandler handles VPN-related requests
type VPNHandler struct {
	vpnManager VPNManager
}

// VPNManager interface for VPN operations
type VPNManager interface {
	Start(profileID string) error
	Stop() error
	GetStatus() (*VPNStatus, error)
	GetStats() (*VPNStats, error)
}

// VPNStatus represents VPN connection status
type VPNStatus struct {
	Status      string    `json:"status"` // connected, disconnected, connecting
	ProfileID   string    `json:"profileId,omitempty"`
	ConnectedAt time.Time `json:"connectedAt,omitempty"`
	UploadSpeed int64     `json:"uploadSpeed"`
	DownSpeed   int64     `json:"downloadSpeed"`
}

// VPNStats represents VPN traffic statistics
type VPNStats struct {
	Upload        int64 `json:"upload"`
	Download      int64 `json:"download"`
	UploadSpeed   int64 `json:"uploadSpeed"`
	DownloadSpeed int64 `json:"downloadSpeed"`
}

// NewVPNHandler creates a new VPNHandler
func NewVPNHandler(vpnManager VPNManager) *VPNHandler {
	return &VPNHandler{
		vpnManager: vpnManager,
	}
}

// Start starts the VPN connection
func (h *VPNHandler) Start(c *gin.Context) {
	var req struct {
		ProfileID string `json:"profileId" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
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

	log.Printf("[VPNHandler] VPN started successfully")

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "connected",
	}))
}

// Stop stops the VPN connection
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

	log.Printf("[VPNHandler] VPN stopped successfully")

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "disconnected",
	}))
}

// GetStatus returns the current VPN status
func (h *VPNHandler) GetStatus(c *gin.Context) {
	log.Printf("[VPNHandler] GetStatus called")

	status, err := h.vpnManager.GetStatus()
	if err != nil {
		log.Printf("[VPNHandler] ERROR: Failed to get status: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrVPNError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(status))
}

// GetStats returns VPN traffic statistics
func (h *VPNHandler) GetStats(c *gin.Context) {
	log.Printf("[VPNHandler] GetStats called")

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
