package cloud

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	keyringServiceName = "PrivateDeploy"
	secretStoreDirEnv  = "PRIVATEDEPLOY_SECRET_STORE_DIR"
)

var errSecretNotFound = errors.New("provider secret not found")

// PrepareProviderConfigForSave stores the API key in the configured secret
// backend and returns a sanitized clone for on-disk JSON persistence.
func PrepareProviderConfigForSave(configPath string, config *ProviderConfig) (*ProviderConfig, error) {
	if config == nil {
		return nil, ErrInvalidConfig
	}

	sanitized := *config
	if config.Extra != nil {
		sanitized.Extra = cloneStringMap(config.Extra)
	}

	apiKey := strings.TrimSpace(config.APIKey)
	if apiKey == "" {
		if err := deleteProviderAPIKey(configPath, config.Provider); err != nil {
			return nil, err
		}
		sanitized.APIKey = ""
		return &sanitized, nil
	}

	if err := saveProviderAPIKey(configPath, config.Provider, apiKey); err != nil {
		return nil, err
	}

	sanitized.APIKey = ""
	return &sanitized, nil
}

// RestoreProviderAPIKey loads the API key from the configured secret backend.
// If a legacy plaintext API key is still present in the config file, it is
// migrated into the secret backend and the caller is told to rewrite the file.
func RestoreProviderAPIKey(configPath string, config *ProviderConfig) (bool, error) {
	if config == nil {
		return false, ErrInvalidConfig
	}

	plaintext := strings.TrimSpace(config.APIKey)
	secret, err := loadProviderAPIKey(configPath, config.Provider)
	if err == nil {
		config.APIKey = secret
		return plaintext != "", nil
	}
	if !errors.Is(err, errSecretNotFound) {
		return false, err
	}

	if plaintext == "" {
		config.APIKey = ""
		return false, nil
	}

	if err := saveProviderAPIKey(configPath, config.Provider, plaintext); err != nil {
		return false, fmt.Errorf("failed to migrate provider API key into secure storage: %w", err)
	}
	config.APIKey = plaintext
	return true, nil
}

func saveProviderAPIKey(configPath, provider, apiKey string) error {
	secret := strings.TrimSpace(apiKey)
	if secret == "" {
		return nil
	}

	storeDir := strings.TrimSpace(os.Getenv(secretStoreDirEnv))
	if storeDir != "" {
		return writeFileSecret(storeDir, configPath, provider, secret)
	}

	return platformSaveSecret(configPath, provider, secret)
}

func loadProviderAPIKey(configPath, provider string) (string, error) {
	storeDir := strings.TrimSpace(os.Getenv(secretStoreDirEnv))
	if storeDir != "" {
		return readFileSecret(storeDir, configPath, provider)
	}

	return platformLoadSecret(configPath, provider)
}

func deleteProviderAPIKey(configPath, provider string) error {
	storeDir := strings.TrimSpace(os.Getenv(secretStoreDirEnv))
	if storeDir != "" {
		path := fileSecretPath(storeDir, configPath, provider)
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("failed to remove %s secret file: %w", provider, err)
		}
		return nil
	}

	return platformDeleteSecret(configPath, provider)
}

func providerSecretKey(configPath, provider string) string {
	sum := sha256.Sum256([]byte(configPath))
	return fmt.Sprintf("cloud/%s/%s", provider, hex.EncodeToString(sum[:8]))
}

func fileSecretPath(storeDir, configPath, provider string) string {
	secretID := strings.ReplaceAll(providerSecretKey(configPath, provider), "/", "_")
	return filepath.Join(storeDir, fmt.Sprintf("%s.secret", secretID))
}

func writeFileSecret(storeDir, configPath, provider, secret string) error {
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return fmt.Errorf("failed to create secret store directory: %w", err)
	}

	payload, err := json.Marshal(map[string]string{"apiKey": secret})
	if err != nil {
		return fmt.Errorf("failed to encode secret payload: %w", err)
	}

	if err := os.WriteFile(fileSecretPath(storeDir, configPath, provider), payload, 0o600); err != nil {
		return fmt.Errorf("failed to write secret payload: %w", err)
	}
	return nil
}

func readFileSecret(storeDir, configPath, provider string) (string, error) {
	path := fileSecretPath(storeDir, configPath, provider)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", errSecretNotFound
	}
	if err != nil {
		return "", fmt.Errorf("failed to read secret payload: %w", err)
	}

	var payload map[string]string
	if err := json.Unmarshal(data, &payload); err != nil {
		return "", fmt.Errorf("failed to decode secret payload: %w", err)
	}

	value := strings.TrimSpace(payload["apiKey"])
	if value == "" {
		return "", errSecretNotFound
	}
	return value, nil
}

func cloneStringMap(input map[string]string) map[string]string {
	if input == nil {
		return nil
	}

	out := make(map[string]string, len(input))
	for key, value := range input {
		out[key] = value
	}
	return out
}

// linuxSecretStoreDir is the default file-backed secret store location on
// Linux. We always use it (instead of the Secret Service / godbus path) so
// that bridge/cloud doesn't transitively pull github.com/godbus/dbus/v5 into
// the main binary — its package init() races WebKitGTK's JSC initialization
// and crashes the process at gtk_main on noble.
func linuxDefaultSecretStoreDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".config", "PrivateDeploy", "secrets")
	}
	return ""
}
