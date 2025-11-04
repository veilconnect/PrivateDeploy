package handlers

import (
	"context"
	"log"
	"net/http"
	"privatedeploy/api/models"

	"github.com/gin-gonic/gin"
)

// CloudManager interface for cloud operations
type CloudManager interface {
	ListProviders() []string
	GetProvider(name string) (CloudProvider, error)
	GetActiveProvider() (CloudProvider, error)
	SetActiveProvider(name string) error
}

// CloudHandler handles cloud-related requests
type CloudHandler struct {
	cloudManager CloudManager
}

// CloudProvider interface (simplified for API server)
type CloudProvider interface {
	Name() string
	DisplayName() string
	LoadConfig() (*ProviderConfig, error)
	SaveConfig(*ProviderConfig) error
	ValidateConfig(*ProviderConfig) error
	ListInstances(ctx context.Context) ([]Instance, error)
	CreateInstance(ctx context.Context, opts *CreateInstanceOptions) (*Instance, error)
	DestroyInstance(ctx context.Context, id string) error
	ListRegions(ctx context.Context) ([]Region, error)
	ListPlans(ctx context.Context, region string) ([]Plan, error)
	ListAvailability(ctx context.Context, region string) ([]Plan, error)
}

// ProviderConfig represents cloud provider configuration
type ProviderConfig struct {
	Provider      string            `json:"provider"`
	APIKey        string            `json:"apiKey"`
	DefaultRegion string            `json:"defaultRegion"`
	DefaultPlan   string            `json:"defaultPlan"`
	Extra         map[string]string `json:"extra"`
}

// Instance represents a cloud instance
type Instance struct {
	ID        string   `json:"id"`
	Label     string   `json:"label"`
	Status    string   `json:"status"`
	Region    string   `json:"region"`
	Plan      string   `json:"plan"`
	IPv4      string   `json:"ipv4"`
	IPv6      string   `json:"ipv6"`
	CreatedAt string   `json:"createdAt"`
	Tags      []string `json:"tags,omitempty"`
}

// CreateInstanceOptions represents options for creating an instance
type CreateInstanceOptions struct {
	Region     string `json:"region" binding:"required"`
	Plan       string `json:"plan" binding:"required"`
	Label      string `json:"label" binding:"required"`
	OSId       string `json:"osId"`
	EnableIPv6 bool   `json:"enableIpv6"`
}

// Region represents a cloud region
type Region struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Country   string `json:"country"`
	Available bool   `json:"available"`
}

// Plan represents a cloud plan
type Plan struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	VCPU      int     `json:"vcpu"`
	RAM       int     `json:"ram"`
	Disk      int     `json:"disk"`
	Bandwidth int     `json:"bandwidth"`
	Price     float64 `json:"price"`
}

// NewCloudHandler creates a new CloudHandler
func NewCloudHandler(cloudManager CloudManager) *CloudHandler {
	return &CloudHandler{
		cloudManager: cloudManager,
	}
}

// ListProviders returns all available cloud providers
func (h *CloudHandler) ListProviders(c *gin.Context) {
	log.Printf("[CloudHandler] ListProviders called")

	providers := h.cloudManager.ListProviders()

	type ProviderInfo struct {
		Name        string `json:"name"`
		DisplayName string `json:"displayName"`
		Enabled     bool   `json:"enabled"`
	}

	result := make([]ProviderInfo, 0, len(providers))
	for _, name := range providers {
		provider, err := h.cloudManager.GetProvider(name)
		if err != nil {
			log.Printf("[CloudHandler] Warning: Failed to get provider %s: %v", name, err)
			continue
		}

		result = append(result, ProviderInfo{
			Name:        provider.Name(),
			DisplayName: provider.DisplayName(),
			Enabled:     true,
		})
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"providers": result,
	}))
}

// GetActiveProvider returns the current active provider
func (h *CloudHandler) GetActiveProvider(c *gin.Context) {
	log.Printf("[CloudHandler] GetActiveProvider called")

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudHandler] ERROR: No active provider: %v", err)
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider set",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"name":        provider.Name(),
		"displayName": provider.DisplayName(),
	}))
}

// SetActiveProvider sets the active cloud provider
func (h *CloudHandler) SetActiveProvider(c *gin.Context) {
	var req struct {
		Provider string `json:"provider" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] SetActiveProvider: %s", req.Provider)

	if err := h.cloudManager.SetActiveProvider(req.Provider); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to set provider: %v", err)
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"provider": req.Provider,
	}))
}

// GetConfig returns the configuration for the active provider
func (h *CloudHandler) GetConfig(c *gin.Context) {
	log.Printf("[CloudHandler] GetConfig called")

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	cfg, err := provider.LoadConfig()
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to load config: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to load configuration",
		))
		return
	}

	if cfg == nil {
		cfg = &ProviderConfig{
			Provider: provider.Name(),
			Extra:    map[string]string{},
		}
	}

	c.JSON(http.StatusOK, models.SuccessResponse(cfg))
}

// SaveConfig saves the configuration for the active provider
func (h *CloudHandler) SaveConfig(c *gin.Context) {
	var cfg ProviderConfig

	if err := c.ShouldBindJSON(&cfg); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] SaveConfig for provider: %s", cfg.Provider)

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	if cfg.Provider != provider.Name() {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Provider mismatch",
		))
		return
	}

	if err := provider.ValidateConfig(&cfg); err != nil {
		log.Printf("[CloudHandler] ERROR: Config validation failed: %v", err)
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			err.Error(),
		))
		return
	}

	if err := provider.SaveConfig(&cfg); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to save config: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to save configuration",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Configuration saved successfully",
	}))
}

// ListInstances returns all instances for the active provider
func (h *CloudHandler) ListInstances(c *gin.Context) {
	log.Printf("[CloudHandler] ListInstances called")

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	instances, err := provider.ListInstances(c.Request.Context())
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list instances: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"instances": instances,
	}))
}

// CreateInstance creates a new instance
func (h *CloudHandler) CreateInstance(c *gin.Context) {
	var opts CreateInstanceOptions

	if err := c.ShouldBindJSON(&opts); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] CreateInstance: region=%s, plan=%s, label=%s",
		opts.Region, opts.Plan, opts.Label)

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	instance, err := provider.CreateInstance(c.Request.Context(), &opts)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to create instance: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Instance created: %s", instance.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"instance": instance,
	}))
}

// DestroyInstance destroys an instance
func (h *CloudHandler) DestroyInstance(c *gin.Context) {
	instanceID := c.Param("id")

	log.Printf("[CloudHandler] DestroyInstance: %s", instanceID)

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	if err := provider.DestroyInstance(c.Request.Context(), instanceID); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to destroy instance: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Instance destroyed: %s", instanceID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Instance destroyed successfully",
	}))
}

// ListRegions returns all regions for the active provider
func (h *CloudHandler) ListRegions(c *gin.Context) {
	log.Printf("[CloudHandler] ListRegions called")

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	regions, err := provider.ListRegions(c.Request.Context())
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list regions: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"regions": regions,
	}))
}

// ListPlans returns all plans for the active provider
func (h *CloudHandler) ListPlans(c *gin.Context) {
	log.Printf("[CloudHandler] ListPlans called")

	region := c.Query("region")

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	plans, err := provider.ListPlans(c.Request.Context(), region)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list plans: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"plans": plans,
	}))
}

// ListAvailability returns plan availability for a region
func (h *CloudHandler) ListAvailability(c *gin.Context) {
	region := c.Query("region")

	log.Printf("[CloudHandler] ListAvailability for region: %s", region)

	provider, err := h.cloudManager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	plans, err := provider.ListAvailability(c.Request.Context(), region)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list availability: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"plans": plans,
	}))
}
