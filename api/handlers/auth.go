package handlers

import (
	"log"
	"net/http"
	"privatedeploy/api/config"
	"privatedeploy/api/models"
	"privatedeploy/api/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// AuthHandler handles authentication-related requests
type AuthHandler struct {
	db  *gorm.DB
	cfg *config.Config
}

// NewAuthHandler creates a new AuthHandler
func NewAuthHandler(db *gorm.DB, cfg *config.Config) *AuthHandler {
	return &AuthHandler{
		db:  db,
		cfg: cfg,
	}
}

// Login handles user login
func (h *AuthHandler) Login(c *gin.Context) {
	var req models.LoginRequest

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	// Find user
	var user models.User
	if err := h.db.Where("username = ?", req.Username).First(&user).Error; err != nil {
		log.Printf("[AuthHandler] Login failed: user not found - %s", req.Username)
		c.JSON(http.StatusUnauthorized, models.ErrorResponse(
			models.ErrInvalidCredentials,
			"Invalid username or password",
		))
		return
	}

	// Check password
	if !utils.CheckPassword(req.Password, user.Password) {
		log.Printf("[AuthHandler] Login failed: wrong password - %s", req.Username)
		c.JSON(http.StatusUnauthorized, models.ErrorResponse(
			models.ErrInvalidCredentials,
			"Invalid username or password",
		))
		return
	}

	// Generate token
	token, err := utils.GenerateToken(user.ID, user.Username, h.cfg.JWT.Secret, h.cfg.JWT.ExpireTime)
	if err != nil {
		log.Printf("[AuthHandler] Failed to generate token: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to generate token",
		))
		return
	}

	log.Printf("[AuthHandler] Login successful: %s", req.Username)

	c.JSON(http.StatusOK, models.SuccessResponse(models.LoginResponse{
		Token:     token,
		ExpiresIn: int64(h.cfg.JWT.ExpireTime.Seconds()),
	}))
}

// Refresh handles token refresh
func (h *AuthHandler) Refresh(c *gin.Context) {
	// Get user info from context (set by auth middleware)
	userID, _ := c.Get("userID")
	username, _ := c.Get("username")

	// Generate new token
	token, err := utils.GenerateToken(userID.(uint), username.(string), h.cfg.JWT.Secret, h.cfg.JWT.ExpireTime)
	if err != nil {
		log.Printf("[AuthHandler] Failed to refresh token: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to refresh token",
		))
		return
	}

	log.Printf("[AuthHandler] Token refreshed for user: %s", username)

	c.JSON(http.StatusOK, models.SuccessResponse(models.LoginResponse{
		Token:     token,
		ExpiresIn: int64(h.cfg.JWT.ExpireTime.Seconds()),
	}))
}
