package config

import (
	"fmt"
	"net"
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

	host := getEnv("API_HOST", "127.0.0.1")
	allowRemote := getEnvBool("API_ALLOW_REMOTE", false)

	// Fail closed: an API that is reachable from anywhere other than loopback
	// must not be exposed without a shared token. Otherwise a single
	// API_ALLOW_REMOTE=true (or a non-loopback bind) would publish the full
	// cloud-provisioning + credential surface unauthenticated.
	if (allowRemote || !isLoopbackHost(host)) && strings.TrimSpace(authToken) == "" {
		return nil, fmt.Errorf(
			"API_AUTH_TOKEN is required when the API is reachable remotely " +
				"(API_ALLOW_REMOTE=true or a non-loopback API_HOST); set API_AUTH_TOKEN or API_AUTH_TOKEN_FILE",
		)
	}

	return &Config{
		Server: ServerConfig{
			Host:         host,
			Port:         getEnv("API_PORT", "8443"),
			ReadTimeout:  10 * time.Second,
			WriteTimeout: writeTimeout,
			AllowRemote:  allowRemote,
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

// isLoopbackHost reports whether binding to host only exposes the loopback
// interface. An empty host or 0.0.0.0/:: (wildcard bind) is treated as
// non-loopback because it accepts remote connections.
func isLoopbackHost(host string) bool {
	host = strings.TrimSpace(host)
	host = strings.Trim(host, "[]")
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// A non-IP, non-localhost hostname may resolve anywhere; treat as remote.
		return false
	}
	return ip.IsLoopback()
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
