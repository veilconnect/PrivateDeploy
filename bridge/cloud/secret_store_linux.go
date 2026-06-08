//go:build linux

package cloud

import (
	"fmt"
	"os"
)

// On Linux we deliberately do NOT call go-keyring (Secret Service / godbus).
// Instead, we file-back to ~/.config/PrivateDeploy/secrets/. PRIVATEDEPLOY_SECRET_STORE_DIR
// overrides the location.

func platformSaveSecret(configPath, provider, secret string) error {
	dir := linuxDefaultSecretStoreDir()
	if dir == "" {
		return fmt.Errorf("cannot resolve home directory for secret store")
	}
	return writeFileSecret(dir, configPath, provider, secret)
}

func platformLoadSecret(configPath, provider string) (string, error) {
	dir := linuxDefaultSecretStoreDir()
	if dir == "" {
		return "", errSecretNotFound
	}
	return readFileSecret(dir, configPath, provider)
}

func platformDeleteSecret(configPath, provider string) error {
	dir := linuxDefaultSecretStoreDir()
	if dir == "" {
		return nil
	}
	path := fileSecretPath(dir, configPath, provider)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove %s secret file: %w", provider, err)
	}
	return nil
}
