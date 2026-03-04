package config

import (
	"os"
	"strings"
	"time"
)

// Config holds the application configuration
type Config struct {
	Server   ServerConfig
	JWT      JWTConfig
	Database DatabaseConfig
	CORS     CORSConfig
}

// ServerConfig holds server-related configuration
type ServerConfig struct {
	Host         string
	Port         string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
}

// JWTConfig holds JWT-related configuration
type JWTConfig struct {
	Secret     string
	ExpireTime time.Duration
}

// DatabaseConfig holds database configuration
type DatabaseConfig struct {
	Path string
}

// CORSConfig holds cross-origin settings
type CORSConfig struct {
	AllowedOrigins []string
}

// Load loads configuration from environment variables with defaults
func Load() *Config {
	return &Config{
		Server: ServerConfig{
			Host:         getEnv("API_HOST", "0.0.0.0"),
			Port:         getEnv("API_PORT", "8443"),
			ReadTimeout:  10 * time.Second,
			WriteTimeout: 10 * time.Second,
		},
		JWT: JWTConfig{
			Secret:     getEnv("JWT_SECRET", "privatedeploy-secret-change-me"),
			ExpireTime: 24 * time.Hour,
		},
		Database: DatabaseConfig{
			Path: getEnv("DB_PATH", "data/privatedeploy.db"),
		},
		CORS: CORSConfig{
			AllowedOrigins: parseCSV(getEnv(
				"CORS_ALLOW_ORIGINS",
				"http://localhost:5173,http://127.0.0.1:5173",
			)),
		},
	}
}

// getEnv gets environment variable with fallback
func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func parseCSV(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, item := range parts {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		result = append(result, trimmed)
	}
	return result
}
