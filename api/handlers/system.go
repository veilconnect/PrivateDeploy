package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"runtime"
	"time"

	"github.com/gin-gonic/gin"
)

// SystemHandler handles system-related requests
type SystemHandler struct {
	version  string
	basePath string
	started  time.Time
}

// NewSystemHandler creates a new SystemHandler
func NewSystemHandler(version, basePath string) *SystemHandler {
	return &SystemHandler{
		version:  version,
		basePath: basePath,
		started:  time.Now(),
	}
}

// SystemInfo represents system information
type SystemInfo struct {
	AppName   string     `json:"appName"`
	Version   string     `json:"version"`
	OS        string     `json:"os"`
	Arch      string     `json:"arch"`
	BasePath  string     `json:"basePath"`
	GoVersion string     `json:"goVersion"`
	Platform  string     `json:"platform"`
	Uptime    int64      `json:"uptime"`
	Memory    MemoryInfo `json:"memory"`
	CPU       CPUInfo    `json:"cpu"`
}

type MemoryInfo struct {
	Total uint64 `json:"total"`
	Used  uint64 `json:"used"`
	Free  uint64 `json:"free"`
}

type CPUInfo struct {
	Cores int     `json:"cores"`
	Usage float64 `json:"usage"`
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
		Platform:  runtime.GOOS + "/" + runtime.GOARCH,
		Uptime:    int64(time.Since(h.started).Seconds()),
		CPU: CPUInfo{
			Cores: runtime.NumCPU(),
			Usage: 0,
		},
	}

	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	total := ms.Sys
	used := ms.Alloc
	var free uint64
	if total > used {
		free = total - used
	}
	info.Memory = MemoryInfo{
		Total: total,
		Used:  used,
		Free:  free,
	}

	c.JSON(http.StatusOK, models.SuccessResponse(info))
}

// Health checks API health
func (h *SystemHandler) Health(c *gin.Context) {
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"status": "healthy",
	}))
}
