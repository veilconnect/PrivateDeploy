package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"privatedeploy/api/models"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// ProfileHandler handles profile-related requests.
type ProfileHandler struct {
	db *gorm.DB
}

// NewProfileHandler creates a new ProfileHandler.
func NewProfileHandler(db *gorm.DB) *ProfileHandler {
	// Auto migrate
	_ = db.AutoMigrate(&models.Profile{})

	return &ProfileHandler{
		db: db,
	}
}

func configToString(v any) string {
	switch value := v.(type) {
	case nil:
		return "{}"
	case string:
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			return "{}"
		}
		return trimmed
	case json.RawMessage:
		trimmed := strings.TrimSpace(string(value))
		if trimmed == "" {
			return "{}"
		}
		return trimmed
	default:
		b, err := json.Marshal(value)
		if err != nil {
			return "{}"
		}
		return string(b)
	}
}

func parseProfileID(raw string) (uint, error) {
	id, err := strconv.ParseUint(strings.TrimSpace(raw), 10, 64)
	if err != nil || id == 0 {
		return 0, fmt.Errorf("invalid profile id: %s", raw)
	}
	return uint(id), nil
}

func profileResponsePayload(p models.Profile) gin.H {
	payload := gin.H{
		"id":               p.ID,
		"name":             p.Name,
		"type":             p.Type,
		"config":           decodeConfigIfJSON(p.Config),
		"active":           p.Active,
		"is_active":        p.Active,
		"subscription_url": p.SubscriptionURL,
		"createdAt":        p.CreatedAt,
		"updatedAt":        p.UpdatedAt,
		"created_at":       p.CreatedAt,
		"updated_at":       p.UpdatedAt,
	}

	if p.LastUpdated != nil {
		payload["lastUpdated"] = *p.LastUpdated
		payload["last_updated"] = *p.LastUpdated
	}

	return payload
}

func decodeConfigIfJSON(raw string) any {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return map[string]any{}
	}

	var out any
	if err := json.Unmarshal([]byte(trimmed), &out); err == nil {
		return out
	}
	return trimmed
}

func (h *ProfileHandler) findByParamID(c *gin.Context) (*models.Profile, error) {
	id, err := parseProfileID(c.Param("id"))
	if err != nil {
		return nil, err
	}

	var profile models.Profile
	if err := h.db.First(&profile, id).Error; err != nil {
		return nil, err
	}

	return &profile, nil
}

// List returns all profiles.
func (h *ProfileHandler) List(c *gin.Context) {
	log.Printf("[ProfileHandler] List called")

	var profiles []models.Profile
	if err := h.db.Order("created_at DESC").Find(&profiles).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to list profiles: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to list profiles",
		))
		return
	}

	items := make([]gin.H, 0, len(profiles))
	for _, p := range profiles {
		items = append(items, profileResponsePayload(p))
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profiles": items,
	}))
}

// GetActive returns the currently active profile.
func (h *ProfileHandler) GetActive(c *gin.Context) {
	var profile models.Profile
	err := h.db.Where("active = ?", true).Order("updated_at DESC").First(&profile).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Active profile not found",
			))
			return
		}
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to get active profile",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(profileResponsePayload(profile)))
}

// SetActive marks a profile as active and clears active state from others.
func (h *ProfileHandler) SetActive(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
			return
		}
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid profile id",
		))
		return
	}

	now := time.Now()
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.Profile{}).Where("active = ?", true).Update("active", false).Error; err != nil {
			return err
		}
		profile.Active = true
		profile.LastUpdated = &now
		return tx.Save(profile).Error
	})
	if err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to set active profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to activate profile",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(profileResponsePayload(*profile)))
}

// Get returns a single profile by ID.
func (h *ProfileHandler) Get(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profileResponsePayload(*profile),
	}))
}

// Create creates a new profile.
func (h *ProfileHandler) Create(c *gin.Context) {
	var req struct {
		Name            string `json:"name" binding:"required"`
		Type            string `json:"type"`
		Config          any    `json:"config"`
		SubscriptionURL string `json:"subscription_url"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	profile := models.Profile{
		Name:            strings.TrimSpace(req.Name),
		Type:            strings.TrimSpace(req.Type),
		Config:          configToString(req.Config),
		SubscriptionURL: strings.TrimSpace(req.SubscriptionURL),
		Active:          false,
	}

	if profile.Name == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Profile name cannot be empty",
		))
		return
	}

	if err := h.db.Create(&profile).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to create profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to create profile",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profileResponsePayload(profile),
	}))
}

// Update updates a profile.
func (h *ProfileHandler) Update(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	var req struct {
		Name            *string `json:"name"`
		Type            *string `json:"type"`
		Config          any     `json:"config"`
		SubscriptionURL *string `json:"subscription_url"`
		Active          *bool   `json:"active"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	now := time.Now()
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if req.Name != nil {
			profile.Name = strings.TrimSpace(*req.Name)
		}
		if req.Type != nil {
			profile.Type = strings.TrimSpace(*req.Type)
		}
		if req.Config != nil {
			profile.Config = configToString(req.Config)
		}
		if req.SubscriptionURL != nil {
			profile.SubscriptionURL = strings.TrimSpace(*req.SubscriptionURL)
		}
		if req.Active != nil {
			if *req.Active {
				if err := tx.Model(&models.Profile{}).Where("active = ?", true).Update("active", false).Error; err != nil {
					return err
				}
			}
			profile.Active = *req.Active
		}
		profile.LastUpdated = &now

		return tx.Save(profile).Error
	})
	if err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to update profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to update profile",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profileResponsePayload(*profile),
	}))
}

// GetContent returns raw profile configuration content.
func (h *ProfileHandler) GetContent(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	content := strings.TrimSpace(profile.Config)
	if content == "" {
		content = "{}"
	}
	c.JSON(http.StatusOK, models.SuccessResponse(content))
}

// UpdateContent updates raw profile configuration content.
func (h *ProfileHandler) UpdateContent(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	var req struct {
		Content string `json:"content" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	now := time.Now()
	profile.Config = configToString(req.Content)
	profile.LastUpdated = &now
	if err := h.db.Save(profile).Error; err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to save profile content",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Profile content saved",
	}))
}

// UpdateSubscription marks subscription update timestamp for a profile.
func (h *ProfileHandler) UpdateSubscription(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	now := time.Now()
	profile.LastUpdated = &now
	if err := h.db.Save(profile).Error; err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to update subscription",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profileResponsePayload(*profile),
		"message": "Subscription updated",
	}))
}

// Delete deletes a profile.
func (h *ProfileHandler) Delete(c *gin.Context) {
	profile, err := h.findByParamID(c)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusBadRequest, models.ErrorResponse(
				models.ErrValidationError,
				"Invalid profile id",
			))
		}
		return
	}

	if err := h.db.Delete(profile).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to delete profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to delete profile",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Profile deleted successfully",
	}))
}
