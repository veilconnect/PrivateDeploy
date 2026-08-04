package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLookupEnvOrFile_EnvTakesPrecedence(t *testing.T) {
	t.Setenv("TEST_SECRET", "from-env")
	t.Setenv("TEST_SECRET_FILE", filepath.Join(t.TempDir(), "secret.txt"))

	value, found, err := LookupEnvOrFile("TEST_SECRET", "TEST_SECRET_FILE")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !found {
		t.Fatal("expected value to be found")
	}
	if value != "from-env" {
		t.Fatalf("expected env value, got %q", value)
	}
}

func TestLookupEnvOrFile_ReadsFileWhenEnvMissing(t *testing.T) {
	secretPath := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(secretPath, []byte("from-file\n"), 0o600); err != nil {
		t.Fatalf("write secret file: %v", err)
	}
	t.Setenv("TEST_SECRET_FILE", secretPath)

	value, found, err := LookupEnvOrFile("TEST_SECRET", "TEST_SECRET_FILE")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !found {
		t.Fatal("expected value to be found")
	}
	if value != "from-file" {
		t.Fatalf("expected trimmed file value, got %q", value)
	}
}

func TestLookupEnvOrFile_MissingFileReturnsError(t *testing.T) {
	t.Setenv("TEST_SECRET_FILE", filepath.Join(t.TempDir(), "missing.txt"))

	_, _, err := LookupEnvOrFile("TEST_SECRET", "TEST_SECRET_FILE")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestLookupEnvOrFile_EmptyFileReturnsError(t *testing.T) {
	secretPath := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(secretPath, []byte(" \n "), 0o600); err != nil {
		t.Fatalf("write secret file: %v", err)
	}
	t.Setenv("TEST_SECRET_FILE", secretPath)

	_, _, err := LookupEnvOrFile("TEST_SECRET", "TEST_SECRET_FILE")
	if err == nil {
		t.Fatal("expected error for empty file")
	}
}

func TestLoad_UsesAPIWriteTimeoutEnv(t *testing.T) {
	t.Setenv("API_WRITE_TIMEOUT", "90s")
	// Keep the default token generation from writing into the working tree.
	t.Setenv("API_AUTH_TOKEN", "test-secret")
	t.Setenv("API_IDEMPOTENCY_SECRET", "test-idempotency-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.WriteTimeout != 90*time.Second {
		t.Fatalf("expected API write timeout from env, got %s", cfg.Server.WriteTimeout)
	}
}

func TestLoad_UsesDefaultDatabasePath(t *testing.T) {
	// Keep the default token generation from writing into the working tree.
	t.Setenv("API_AUTH_TOKEN", "test-secret")
	t.Setenv("API_IDEMPOTENCY_SECRET", "test-idempotency-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.Host != "127.0.0.1" {
		t.Fatalf("expected localhost default host, got %q", cfg.Server.Host)
	}
	if cfg.Database.Path != "data/privatedeploy.db" {
		t.Fatalf("expected default database path, got %q", cfg.Database.Path)
	}
}

func TestLoad_ReadsAPIAuthTokenFromFile(t *testing.T) {
	secretPath := filepath.Join(t.TempDir(), "token.txt")
	if err := os.WriteFile(secretPath, []byte("shared-secret\n"), 0o600); err != nil {
		t.Fatalf("write token file: %v", err)
	}
	t.Setenv("API_AUTH_TOKEN_FILE", secretPath)
	t.Setenv("API_IDEMPOTENCY_SECRET", "test-idempotency-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.AuthToken != "shared-secret" {
		t.Fatalf("expected auth token from file, got %q", cfg.Server.AuthToken)
	}
}

func TestLoad_UsesAllowRemoteBoolEnv(t *testing.T) {
	t.Setenv("API_ALLOW_REMOTE", "true")
	// Remote access now requires a token; provide one so this test exercises
	// only the allow-remote parsing.
	t.Setenv("API_AUTH_TOKEN", "shared-secret")
	t.Setenv("API_IDEMPOTENCY_SECRET", "test-idempotency-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cfg.Server.AllowRemote {
		t.Fatal("expected allowRemote to be true")
	}
}

func TestLoad_RemoteWithoutTokenFailsClosed(t *testing.T) {
	t.Setenv("API_ALLOW_REMOTE", "true")

	if _, err := Load(); err == nil {
		t.Fatal("expected Load to reject remote API access without an auth token")
	}
}

func TestLoad_NonLoopbackHostWithoutTokenFailsClosed(t *testing.T) {
	t.Setenv("API_HOST", "0.0.0.0")

	if _, err := Load(); err == nil {
		t.Fatal("expected Load to reject a non-loopback bind without an auth token")
	}
}

func TestLoad_NonLoopbackHostWithTokenSucceeds(t *testing.T) {
	t.Setenv("API_HOST", "0.0.0.0")
	t.Setenv("API_AUTH_TOKEN", "shared-secret")
	t.Setenv("API_IDEMPOTENCY_SECRET", "test-idempotency-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.Host != "0.0.0.0" {
		t.Fatalf("expected configured host, got %q", cfg.Server.Host)
	}
}

// resetAuthEnv clears every auth-related environment variable Load consults
// so a test starts from the documented defaults.
func resetAuthEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"API_AUTH_TOKEN",
		"API_AUTH_TOKEN_FILE",
		"API_AUTH_TOKEN_PATH",
		"API_IDEMPOTENCY_SECRET",
		"API_IDEMPOTENCY_SECRET_FILE",
		"API_IDEMPOTENCY_SECRET_PATH",
		"API_ALLOW_UNAUTHENTICATED",
		"API_ALLOW_REMOTE",
		"API_HOST",
	} {
		t.Setenv(key, "")
	}
}

func TestLoad_GeneratesPersistentTokenByDefault(t *testing.T) {
	resetAuthEnv(t)
	dir := t.TempDir()
	t.Setenv("DB_PATH", filepath.Join(dir, "privatedeploy.db"))

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.Server.AuthTokenSource != AuthTokenSourceGenerated {
		t.Fatalf("expected generated token source, got %q", cfg.Server.AuthTokenSource)
	}
	if cfg.Server.AuthToken == "" {
		t.Fatal("expected a non-empty generated token")
	}
	wantPath := filepath.Join(dir, "api_auth_token")
	if cfg.Server.AuthTokenPath != wantPath {
		t.Fatalf("expected token path %q, got %q", wantPath, cfg.Server.AuthTokenPath)
	}

	info, err := os.Stat(wantPath)
	if err != nil {
		t.Fatalf("token file missing: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("expected token file mode 0600, got %o", info.Mode().Perm())
	}

	// A second load must reuse the persisted token, not mint a new one.
	cfg2, err := Load()
	if err != nil {
		t.Fatalf("second Load: %v", err)
	}
	if cfg2.Server.AuthToken != cfg.Server.AuthToken {
		t.Fatal("expected the generated token to persist across restarts")
	}
}

func TestLoad_ExplicitTokenSkipsGeneration(t *testing.T) {
	resetAuthEnv(t)
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "privatedeploy.db"))
	t.Setenv("API_AUTH_TOKEN", "explicit-secret")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.AuthToken != "explicit-secret" {
		t.Fatalf("expected explicit token, got %q", cfg.Server.AuthToken)
	}
	if cfg.Server.AuthTokenSource != AuthTokenSourceExplicit {
		t.Fatalf("expected explicit token source, got %q", cfg.Server.AuthTokenSource)
	}
	if cfg.Server.AuthTokenPath != "" {
		t.Fatalf("explicit token must not create a token file, got path %q", cfg.Server.AuthTokenPath)
	}
	if cfg.Server.IdempotencySecret == "" || cfg.Server.IdempotencySecret == cfg.Server.AuthToken {
		t.Fatal("expected an independent, non-empty idempotency secret")
	}
	wantIdempotencyPath := filepath.Join(filepath.Dir(cfg.Database.Path), "api_idempotency_secret")
	if cfg.Server.IdempotencySecretPath != wantIdempotencyPath {
		t.Fatalf("expected idempotency secret path %q, got %q", wantIdempotencyPath, cfg.Server.IdempotencySecretPath)
	}
	cfg2, err := Load()
	if err != nil {
		t.Fatalf("second Load: %v", err)
	}
	if cfg2.Server.IdempotencySecret != cfg.Server.IdempotencySecret {
		t.Fatal("expected idempotency secret to persist across restarts")
	}
}

func TestLoad_HonorsExplicitUnauthenticatedSwitch(t *testing.T) {
	resetAuthEnv(t)
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "privatedeploy.db"))
	t.Setenv("API_ALLOW_UNAUTHENTICATED", "true")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.AuthToken != "" {
		t.Fatalf("expected empty token in unauthenticated mode, got %q", cfg.Server.AuthToken)
	}
	if cfg.Server.AuthTokenSource != AuthTokenSourceDisabled {
		t.Fatalf("expected disabled token source, got %q", cfg.Server.AuthTokenSource)
	}
}

func TestLoad_HonorsTokenPathOverride(t *testing.T) {
	resetAuthEnv(t)
	dir := t.TempDir()
	t.Setenv("DB_PATH", filepath.Join(dir, "privatedeploy.db"))
	custom := filepath.Join(dir, "custom", "token.txt")
	t.Setenv("API_AUTH_TOKEN_PATH", custom)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.AuthTokenPath != custom {
		t.Fatalf("expected token path %q, got %q", custom, cfg.Server.AuthTokenPath)
	}
	if _, err := os.Stat(custom); err != nil {
		t.Fatalf("token file missing at override path: %v", err)
	}
}

func TestLoad_UnauthenticatedSwitchDoesNotBypassRemoteFailClosed(t *testing.T) {
	resetAuthEnv(t)
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "privatedeploy.db"))
	t.Setenv("API_ALLOW_REMOTE", "true")
	t.Setenv("API_ALLOW_UNAUTHENTICATED", "true")

	if _, err := Load(); err == nil {
		t.Fatal("expected API_ALLOW_UNAUTHENTICATED to be rejected for remote exposure")
	}
}

func TestLoad_RemoteRejectsGeneratedTokenAsSufficient(t *testing.T) {
	resetAuthEnv(t)
	dir := t.TempDir()
	t.Setenv("DB_PATH", filepath.Join(dir, "privatedeploy.db"))

	// First load generates a local token file...
	if _, err := Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}
	// ...but remote exposure must still demand an explicitly configured token.
	t.Setenv("API_ALLOW_REMOTE", "true")
	if _, err := Load(); err == nil {
		t.Fatal("expected remote exposure to require an explicit token even when a generated one exists")
	}
}

func TestLoad_InvalidAPIWriteTimeoutReturnsError(t *testing.T) {
	t.Setenv("API_WRITE_TIMEOUT", "not-a-duration")

	_, err := Load()
	if err == nil {
		t.Fatal("expected error for invalid API write timeout")
	}
}
