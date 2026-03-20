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

	"github.com/zalando/go-keyring"
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

	if err := keyring.Set(keyringServiceName, providerSecretKey(configPath, provider), secret); err != nil {
		return fmt.Errorf(
			"failed to store %s API key in system keyring: %w (set %s for explicit file-backed fallback in headless environments)",
			provider,
			err,
			secretStoreDirEnv,
		)
	}
	return nil
}

func loadProviderAPIKey(configPath, provider string) (string, error) {
	storeDir := strings.TrimSpace(os.Getenv(secretStoreDirEnv))
	if storeDir != "" {
		return readFileSecret(storeDir, configPath, provider)
	}

	value, err := keyring.Get(keyringServiceName, providerSecretKey(configPath, provider))
	if err != nil {
		if errors.Is(err, keyring.ErrNotFound) {
			return "", errSecretNotFound
		}
		return "", fmt.Errorf("failed to read %s API key from system keyring: %w", provider, err)
	}

	value = strings.TrimSpace(value)
	if value == "" {
		return "", errSecretNotFound
	}
	return value, nil
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

	if err := keyring.Delete(keyringServiceName, providerSecretKey(configPath, provider)); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		return fmt.Errorf("failed to delete %s API key from system keyring: %w", provider, err)
	}
	return nil
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
