package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"privatedeploy/api/models"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// ProfileHandler handles profile-related requests
type ProfileHandler struct {
	db *gorm.DB
}

// Profile represents a VPN configuration profile
type Profile struct {
	ID        uint            `json:"id" gorm:"primaryKey"`
	Name      string          `json:"name" gorm:"not null"`
	Type      string          `json:"type"` // local, remote
	Config    json.RawMessage `json:"config" gorm:"type:text"`
	Active    bool            `json:"active"`
	CreatedAt time.Time       `json:"createdAt"`
	UpdatedAt time.Time       `json:"updatedAt"`
}

// NewProfileHandler creates a new ProfileHandler
func NewProfileHandler(db *gorm.DB) *ProfileHandler {
	// Auto migrate
	db.AutoMigrate(&Profile{})

	return &ProfileHandler{
		db: db,
	}
}

// List returns all profiles
func (h *ProfileHandler) List(c *gin.Context) {
	log.Printf("[ProfileHandler] List called")

	var profiles []Profile
	if err := h.db.Order("created_at DESC").Find(&profiles).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to list profiles: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to list profiles",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profiles": profiles,
	}))
}

// Get returns a single profile by ID
func (h *ProfileHandler) Get(c *gin.Context) {
	id := c.Param("id")
	log.Printf("[ProfileHandler] Get profile: %s", id)

	var profile Profile
	if err := h.db.First(&profile, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			log.Printf("[ProfileHandler] ERROR: Failed to get profile: %v", err)
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get profile",
			))
		}
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profile,
	}))
}

// Create creates a new profile
func (h *ProfileHandler) Create(c *gin.Context) {
	var req struct {
		Name   string          `json:"name" binding:"required"`
		Type   string          `json:"type"`
		Config json.RawMessage `json:"config"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[ProfileHandler] Creating profile: %s", req.Name)

	profile := Profile{
		Name:   req.Name,
		Type:   req.Type,
		Config: req.Config,
		Active: false,
	}

	if err := h.db.Create(&profile).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to create profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to create profile",
		))
		return
	}

	log.Printf("[ProfileHandler] Profile created: %d", profile.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profile,
	}))
}

// Update updates a profile
func (h *ProfileHandler) Update(c *gin.Context) {
	id := c.Param("id")

	var req struct {
		Name   string          `json:"name"`
		Type   string          `json:"type"`
		Config json.RawMessage `json:"config"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[ProfileHandler] Updating profile: %s", id)

	var profile Profile
	if err := h.db.First(&profile, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get profile",
			))
		}
		return
	}

	// Update fields
	if req.Name != "" {
		profile.Name = req.Name
	}
	if req.Type != "" {
		profile.Type = req.Type
	}
	if len(req.Config) > 0 {
		profile.Config = req.Config
	}

	if err := h.db.Save(&profile).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to update profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to update profile",
		))
		return
	}

	log.Printf("[ProfileHandler] Profile updated: %d", profile.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"profile": profile,
	}))
}

// Delete deletes a profile
func (h *ProfileHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	log.Printf("[ProfileHandler] Deleting profile: %s", id)

	var profile Profile
	if err := h.db.First(&profile, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Profile not found",
			))
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get profile",
			))
		}
		return
	}

	if err := h.db.Delete(&profile).Error; err != nil {
		log.Printf("[ProfileHandler] ERROR: Failed to delete profile: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to delete profile",
		))
		return
	}

	log.Printf("[ProfileHandler] Profile deleted: %s", id)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Profile deleted successfully",
	}))
}
