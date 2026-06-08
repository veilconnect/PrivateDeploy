package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds the application configuration
type Config struct {
	Server    ServerConfig
	Database  DatabaseConfig
	CORS      CORSConfig
	RateLimit RateLimitConfig
	Audit     AuditConfig
}

// ServerConfig holds server-related configuration
type ServerConfig struct {
	Host         string
	Port         string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
	AllowRemote  bool
	AuthToken    string
}

// DatabaseConfig holds database configuration
type DatabaseConfig struct {
	Path string
}

// CORSConfig holds cross-origin settings
type CORSConfig struct {
	AllowedOrigins []string
}

// RateLimitConfig holds rate limiting settings.
// Rate is tokens added per second; Burst is the maximum token count.
// Set Rate to 0 to disable rate limiting.
type RateLimitConfig struct {
	Rate  float64
	Burst int
}

// AuditConfig holds audit logging settings.
type AuditConfig struct {
	Enabled bool
	Path    string
}

// Load loads configuration from environment variables with defaults.
func Load() (*Config, error) {
	writeTimeout, err := getEnvDuration("API_WRITE_TIMEOUT", 120*time.Second)
	if err != nil {
		return nil, err
	}

	authToken, _, err := LookupEnvOrFile("API_AUTH_TOKEN", "API_AUTH_TOKEN_FILE")
	if err != nil {
		return nil, err
	}

	return &Config{
		Server: ServerConfig{
			Host:         getEnv("API_HOST", "127.0.0.1"),
			Port:         getEnv("API_PORT", "8443"),
			ReadTimeout:  10 * time.Second,
			WriteTimeout: writeTimeout,
			AllowRemote:  getEnvBool("API_ALLOW_REMOTE", false),
			AuthToken:    authToken,
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
		RateLimit: RateLimitConfig{
			Rate:  getEnvFloat("API_RATE_LIMIT", 10),
			Burst: getEnvInt("API_RATE_BURST", 30),
		},
		Audit: AuditConfig{
			Enabled: getEnvBool("API_AUDIT_LOG", false),
			Path:    getEnv("API_AUDIT_LOG_PATH", "data/audit.log"),
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

func getEnvBool(key string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	switch value {
	case "", "default":
		return fallback
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func getEnvFloat(key string, fallback float64) float64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	f, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return fallback
	}
	return f
}

func getEnvInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return n
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
