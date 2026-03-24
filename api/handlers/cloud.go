package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"strings"

	"github.com/gin-gonic/gin"
)

// CloudHandler handles cloud-related requests
type CloudHandler struct {
	manager *cloud.Manager
}

// NewCloudHandler creates a new CloudHandler
func NewCloudHandler(manager *cloud.Manager) *CloudHandler {
	return &CloudHandler{
		manager: manager,
	}
}

// ListProviders returns all available cloud providers
func (h *CloudHandler) ListProviders(c *gin.Context) {
	log.Printf("[CloudHandler] ListProviders called")

	providerNames := h.manager.ListProviders()

	type ProviderInfo struct {
		Name        string `json:"name"`
		DisplayName string `json:"displayName"`
	}

	result := make([]ProviderInfo, 0, len(providerNames))
	for _, name := range providerNames {
		if !defaults.IsPublicProvider(name) {
			continue
		}
		provider, err := h.manager.GetProvider(name)
		if err != nil {
			log.Printf("[CloudHandler] Warning: Failed to get provider %s: %v", name, err)
			continue
		}

		result = append(result, ProviderInfo{
			Name:        provider.Name(),
			DisplayName: provider.DisplayName(),
		})
	}

	log.Printf("[CloudHandler] Found %d providers", len(result))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"providers": result,
	}))
}

// GetActiveProvider returns the current active provider
func (h *CloudHandler) GetActiveProvider(c *gin.Context) {
	log.Printf("[CloudHandler] GetActiveProvider called")

	provider, err := h.manager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudHandler] ERROR: No active provider: %v", err)
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider set",
		))
		return
	}
	if !defaults.IsPublicProvider(provider.Name()) {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"Active provider is not a public production provider",
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

	if !defaults.IsPublicProvider(req.Provider) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Provider is experimental and not available in this build",
		))
		return
	}

	if err := h.manager.SetActiveProvider(req.Provider); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to set provider: %v", err)
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Active provider set to: %s", req.Provider)
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"provider": req.Provider,
	}))
}

// GetConfig returns the configuration for the active provider
func (h *CloudHandler) GetConfig(c *gin.Context) {
	log.Printf("[CloudHandler] GetConfig called")

	provider, err := h.manager.GetActiveProvider()
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
		cfg = &cloud.ProviderConfig{
			Provider: provider.Name(),
			Extra:    map[string]string{},
		}
	}

	hasAPIKey := strings.TrimSpace(cfg.APIKey) != ""
	response := gin.H{
		"provider":      cfg.Provider,
		"defaultRegion": cfg.DefaultRegion,
		"defaultPlan":   cfg.DefaultPlan,
		"extra":         cfg.Extra,
		"hasApiKey":     hasAPIKey,
	}

	c.JSON(http.StatusOK, models.SuccessResponse(response))
}

// SaveConfig saves the configuration for the active provider
func (h *CloudHandler) SaveConfig(c *gin.Context) {
	var cfg cloud.ProviderConfig

	if err := c.ShouldBindJSON(&cfg); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] SaveConfig for provider: %s", cfg.Provider)

	provider, err := h.manager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	// Ensure provider match
	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
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

	log.Printf("[CloudHandler] Config saved successfully")
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Configuration saved successfully",
	}))
}

// ListInstances returns all instances for the active provider
func (h *CloudHandler) ListInstances(c *gin.Context) {
	log.Printf("[CloudHandler] ListInstances called")

	provider, err := h.manager.GetActiveProvider()
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

	log.Printf("[CloudHandler] Listed %d instances", len(instances))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"instances": instances,
	}))
}

// CreateInstance creates a new instance
func (h *CloudHandler) CreateInstance(c *gin.Context) {
	var opts cloud.CreateInstanceOptions

	if err := c.ShouldBindJSON(&opts); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] CreateInstance: region=%s, plan=%s, label=%s",
		opts.Region, opts.Plan, opts.Label)

	provider, err := h.manager.GetActiveProvider()
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
	c.JSON(http.StatusCreated, models.SuccessResponse(gin.H{
		"instance": instance,
	}))
}

// DestroyInstance destroys an instance
func (h *CloudHandler) DestroyInstance(c *gin.Context) {
	instanceID := c.Param("id")

	log.Printf("[CloudHandler] DestroyInstance: %s", instanceID)

	provider, err := h.manager.GetActiveProvider()
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

	provider, err := h.manager.GetActiveProvider()
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

	log.Printf("[CloudHandler] Listed %d regions", len(regions))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"regions": regions,
	}))
}

// ListPlans returns all plans for the active provider
func (h *CloudHandler) ListPlans(c *gin.Context) {
	region := c.Query("region")
	log.Printf("[CloudHandler] ListPlans called (region: %s)", region)

	provider, err := h.manager.GetActiveProvider()
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

	log.Printf("[CloudHandler] Listed %d plans", len(plans))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"plans": plans,
	}))
}

// ListAvailability returns plan availability for a region
func (h *CloudHandler) ListAvailability(c *gin.Context) {
	region := c.Query("region")
	if region == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"region parameter is required",
		))
		return
	}

	log.Printf("[CloudHandler] ListAvailability for region: %s", region)

	provider, err := h.manager.GetActiveProvider()
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider",
		))
		return
	}

	availability, err := provider.ListAvailability(c.Request.Context(), region)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list availability: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Listed %d available plans", len(availability))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"availability": availability,
	}))
}
