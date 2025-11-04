package config

import (
	"os"
	"time"
)

// Config holds the application configuration
type Config struct {
	Server   ServerConfig
	JWT      JWTConfig
	Database DatabaseConfig
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
	}
}

// getEnv gets environment variable with fallback
func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
