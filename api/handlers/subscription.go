package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/models"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// SubscriptionHandler handles subscription-related requests
type SubscriptionHandler struct {
	db *gorm.DB
}

// Subscription represents a VPN subscription
type Subscription struct {
	ID        uint      `json:"id" gorm:"primaryKey"`
	Name      string    `json:"name" gorm:"not null"`
	URL       string    `json:"url" gorm:"not null"`
	NodeCount int       `json:"nodeCount"`
	UpdatedAt time.Time `json:"updatedAt"`
	CreatedAt time.Time `json:"createdAt"`
}

// NewSubscriptionHandler creates a new SubscriptionHandler
func NewSubscriptionHandler(db *gorm.DB) *SubscriptionHandler {
	// Auto migrate
	db.AutoMigrate(&Subscription{})

	return &SubscriptionHandler{
		db: db,
	}
}

// List returns all subscriptions
func (h *SubscriptionHandler) List(c *gin.Context) {
	log.Printf("[SubscriptionHandler] List called")

	var subscriptions []Subscription
	if err := h.db.Order("created_at DESC").Find(&subscriptions).Error; err != nil {
		log.Printf("[SubscriptionHandler] ERROR: Failed to list subscriptions: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to list subscriptions",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"subscriptions": subscriptions,
	}))
}

// Get returns a single subscription by ID
func (h *SubscriptionHandler) Get(c *gin.Context) {
	id := c.Param("id")
	log.Printf("[SubscriptionHandler] Get subscription: %s", id)

	var subscription Subscription
	if err := h.db.First(&subscription, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Subscription not found",
			))
		} else {
			log.Printf("[SubscriptionHandler] ERROR: Failed to get subscription: %v", err)
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get subscription",
			))
		}
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"subscription": subscription,
	}))
}

// Create creates a new subscription
func (h *SubscriptionHandler) Create(c *gin.Context) {
	var req struct {
		Name string `json:"name" binding:"required"`
		URL  string `json:"url" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Creating subscription: %s", req.Name)

	subscription := Subscription{
		Name:      req.Name,
		URL:       req.URL,
		NodeCount: 0,
	}

	if err := h.db.Create(&subscription).Error; err != nil {
		log.Printf("[SubscriptionHandler] ERROR: Failed to create subscription: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to create subscription",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Subscription created: %d", subscription.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"subscription": subscription,
	}))
}

// Update updates a subscription
func (h *SubscriptionHandler) Update(c *gin.Context) {
	id := c.Param("id")

	var req struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Updating subscription: %s", id)

	var subscription Subscription
	if err := h.db.First(&subscription, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Subscription not found",
			))
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get subscription",
			))
		}
		return
	}

	// Update fields
	if req.Name != "" {
		subscription.Name = req.Name
	}
	if req.URL != "" {
		subscription.URL = req.URL
	}

	if err := h.db.Save(&subscription).Error; err != nil {
		log.Printf("[SubscriptionHandler] ERROR: Failed to update subscription: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to update subscription",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Subscription updated: %d", subscription.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"subscription": subscription,
	}))
}

// Delete deletes a subscription
func (h *SubscriptionHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	log.Printf("[SubscriptionHandler] Deleting subscription: %s", id)

	var subscription Subscription
	if err := h.db.First(&subscription, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Subscription not found",
			))
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get subscription",
			))
		}
		return
	}

	if err := h.db.Delete(&subscription).Error; err != nil {
		log.Printf("[SubscriptionHandler] ERROR: Failed to delete subscription: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to delete subscription",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Subscription deleted: %s", id)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Subscription deleted successfully",
	}))
}

// Refresh refreshes a subscription (fetches latest nodes)
func (h *SubscriptionHandler) Refresh(c *gin.Context) {
	id := c.Param("id")
	log.Printf("[SubscriptionHandler] Refreshing subscription: %s", id)

	var subscription Subscription
	if err := h.db.First(&subscription, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"Subscription not found",
			))
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse(
				models.ErrInternalError,
				"Failed to get subscription",
			))
		}
		return
	}

	// TODO: Implement actual subscription refresh logic
	// This would involve fetching the subscription URL and parsing nodes

	// For now, just update the timestamp
	subscription.UpdatedAt = time.Now()
	if err := h.db.Save(&subscription).Error; err != nil {
		log.Printf("[SubscriptionHandler] ERROR: Failed to update subscription: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to refresh subscription",
		))
		return
	}

	log.Printf("[SubscriptionHandler] Subscription refreshed: %d", subscription.ID)

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"subscription": subscription,
		"message":      "Subscription refreshed successfully",
	}))
}
