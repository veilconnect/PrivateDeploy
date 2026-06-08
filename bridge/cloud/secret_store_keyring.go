//go:build !linux

package cloud

import (
	"errors"
	"fmt"
	"strings"

	"github.com/zalando/go-keyring"
)

// On macOS and Windows we use go-keyring (Keychain / Credential Manager
// respectively). Neither backend pulls godbus on those platforms, so it's
// safe to import here under the !linux build tag.

func platformSaveSecret(configPath, provider, secret string) error {
	if err := keyring.Set(keyringServiceName, providerSecretKey(configPath, provider), secret); err != nil {
		return fmt.Errorf(
			"failed to store %s API key in system keyring: %w (set %s for explicit file-backed fallback in headless environments)",
			provider, err, secretStoreDirEnv,
		)
	}
	return nil
}

func platformLoadSecret(configPath, provider string) (string, error) {
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

func platformDeleteSecret(configPath, provider string) error {
	if err := keyring.Delete(keyringServiceName, providerSecretKey(configPath, provider)); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		return fmt.Errorf("failed to delete %s API key from system keyring: %w", provider, err)
	}
	return nil
}
