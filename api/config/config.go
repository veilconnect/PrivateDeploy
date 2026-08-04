package config

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
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

// Auth token sources, recorded so startup logging can describe where the
// token came from without ever printing the token itself.
const (
	AuthTokenSourceExplicit  = "explicit"  // API_AUTH_TOKEN / API_AUTH_TOKEN_FILE
	AuthTokenSourceGenerated = "generated" // auto-generated persistent token file
	AuthTokenSourceDisabled  = "disabled"  // API_ALLOW_UNAUTHENTICATED=true
)

// ServerConfig holds server-related configuration
type ServerConfig struct {
	Host         string
	Port         string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
	AllowRemote  bool
	AuthToken    string
	// AuthTokenSource is one of the AuthTokenSource* constants.
	AuthTokenSource string
	// AuthTokenPath is the token file location when AuthTokenSource is
	// "generated". Log this path, never the token value.
	AuthTokenPath string
	// IdempotencySecret is an independent persistent random key used only for
	// request fingerprints. It must never be logged or derived from AuthToken.
	IdempotencySecret     string
	IdempotencySecretPath string
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

	authToken, explicitToken, err := LookupEnvOrFile("API_AUTH_TOKEN", "API_AUTH_TOKEN_FILE")
	if err != nil {
		return nil, err
	}

	host := getEnv("API_HOST", "127.0.0.1")
	allowRemote := getEnvBool("API_ALLOW_REMOTE", false)
	dbPath := getEnv("DB_PATH", "data/privatedeploy.db")

	// Fail closed: an API that is reachable from anywhere other than loopback
	// must not be exposed without an explicitly configured shared token.
	// Otherwise a single API_ALLOW_REMOTE=true (or a non-loopback bind) would
	// publish the full cloud-provisioning + credential surface protected only
	// by a locally generated token (or, worse, nothing at all).
	if (allowRemote || !isLoopbackHost(host)) && !explicitToken {
		return nil, fmt.Errorf(
			"API_AUTH_TOKEN is required when the API is reachable remotely " +
				"(API_ALLOW_REMOTE=true or a non-loopback API_HOST); set API_AUTH_TOKEN or API_AUTH_TOKEN_FILE",
		)
	}

	authTokenSource := AuthTokenSourceExplicit
	authTokenPath := ""
	if !explicitToken {
		if getEnvBool("API_ALLOW_UNAUTHENTICATED", false) {
			// Opting out of authentication requires this explicit,
			// unambiguously named switch — and even then only for
			// loopback-only deployments (guaranteed by the check above).
			authToken = ""
			authTokenSource = AuthTokenSourceDisabled
		} else {
			// Secure default: local clients authenticate with a persistent
			// random token stored next to the database, file mode 0600.
			authTokenPath = getEnv("API_AUTH_TOKEN_PATH", filepath.Join(filepath.Dir(dbPath), "api_auth_token"))
			authToken, err = ensurePersistentAuthToken(authTokenPath)
			if err != nil {
				return nil, err
			}
			authTokenSource = AuthTokenSourceGenerated
		}
	}

	// Keep idempotency fingerprints stable across API-token rotation and
	// unauthenticated-mode restarts. This key is deliberately independent of
	// the bearer token so stored request MACs cannot help guess a weak token.
	idempotencySecret, explicitIdempotencySecret, err := LookupEnvOrFile(
		"API_IDEMPOTENCY_SECRET",
		"API_IDEMPOTENCY_SECRET_FILE",
	)
	if err != nil {
		return nil, err
	}
	idempotencySecretPath := ""
	if !explicitIdempotencySecret {
		idempotencySecretPath = getEnv(
			"API_IDEMPOTENCY_SECRET_PATH",
			filepath.Join(filepath.Dir(dbPath), "api_idempotency_secret"),
		)
		idempotencySecret, err = ensurePersistentAuthToken(idempotencySecretPath)
		if err != nil {
			return nil, err
		}
	}

	return &Config{
		Server: ServerConfig{
			Host:                  host,
			Port:                  getEnv("API_PORT", "8443"),
			ReadTimeout:           10 * time.Second,
			WriteTimeout:          writeTimeout,
			AllowRemote:           allowRemote,
			AuthToken:             authToken,
			AuthTokenSource:       authTokenSource,
			AuthTokenPath:         authTokenPath,
			IdempotencySecret:     idempotencySecret,
			IdempotencySecretPath: idempotencySecretPath,
		},
		Database: DatabaseConfig{
			Path: dbPath,
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

// ensurePersistentAuthToken returns the token stored at path, creating a new
// random one (file mode 0600) on first use. The token value must never be
// logged; callers log only the path.
func ensurePersistentAuthToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		token := strings.TrimSpace(string(data))
		if token != "" {
			// Best-effort: keep the file private even if permissions drifted.
			_ = os.Chmod(path, 0o600)
			return token, nil
		}
		// Empty file: fall through and regenerate.
	case !errors.Is(err, os.ErrNotExist):
		return "", fmt.Errorf("failed to read auth token file %q: %w", path, err)
	}

	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", fmt.Errorf("failed to create auth token directory: %w", err)
		}
	}

	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("failed to generate auth token: %w", err)
	}
	token := hex.EncodeToString(buf)

	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("failed to write auth token file %q: %w", path, err)
	}
	return token, nil
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
