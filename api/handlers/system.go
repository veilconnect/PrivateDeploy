package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"runtime"

	"github.com/gin-gonic/gin"
)

// SystemHandler handles system-related requests
type SystemHandler struct {
	version  string
	basePath string
}

// NewSystemHandler creates a new SystemHandler
func NewSystemHandler(version, basePath string) *SystemHandler {
	return &SystemHandler{
		version:  version,
		basePath: basePath,
	}
}

// SystemInfo represents system information
type SystemInfo struct {
	AppName    string `json:"appName"`
	Version    string `json:"version"`
	OS         string `json:"os"`
	Arch       string `json:"arch"`
	BasePath   string `json:"basePath"`
	GoVersion  string `json:"goVersion"`
}

// GetInfo returns system information
func (h *SystemHandler) GetInfo(c *gin.Context) {
	log.Printf("[SystemHandler] GetInfo called")

	info := SystemInfo{
		AppName:   "PrivateDeploy",
		Version:   h.version,
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
		BasePath:  h.basePath,
		GoVersion: runtime.Version(),
	}

	c.JSON(http.StatusOK, models.SuccessResponse(info))
}

// Health checks API health
func (h *SystemHandler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "healthy",
	}))
}
