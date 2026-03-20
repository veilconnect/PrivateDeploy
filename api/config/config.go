package config

import (
	"fmt"
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

// Load loads configuration from environment variables with defaults.
func Load() (*Config, error) {
	jwtSecret, found, err := LookupEnvOrFile("JWT_SECRET", "JWT_SECRET_FILE")
	if err != nil {
		return nil, err
	}
	if !found {
		jwtSecret = ""
	}
	writeTimeout, err := getEnvDuration("API_WRITE_TIMEOUT", 120*time.Second)
	if err != nil {
		return nil, err
	}

	return &Config{
		Server: ServerConfig{
			Host:         getEnv("API_HOST", "0.0.0.0"),
			Port:         getEnv("API_PORT", "8443"),
			ReadTimeout:  10 * time.Second,
			WriteTimeout: writeTimeout,
		},
		JWT: JWTConfig{
			Secret:     jwtSecret,
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
	}, nil
}

// getEnv gets environment variable with fallback
func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func getEnvDuration(key string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}

	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s duration %q: %w", key, value, err)
	}
	return duration, nil
}

// LookupEnvOrFile reads a value from KEY or, if unset, from KEY_FILE.
// The direct environment variable takes precedence. Empty values are treated as unset.
func LookupEnvOrFile(key, fileKey string) (string, bool, error) {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value, true, nil
	}

	filePath := strings.TrimSpace(os.Getenv(fileKey))
	if filePath == "" {
		return "", false, nil
	}

	content, err := os.ReadFile(filePath)
	if err != nil {
		return "", false, fmt.Errorf("failed to read %s=%q: %w", fileKey, filePath, err)
	}

	value := strings.TrimSpace(string(content))
	if value == "" {
		return "", false, fmt.Errorf("%s=%q points to an empty file", fileKey, filePath)
	}

	return value, true, nil
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
