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

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Server.WriteTimeout != 90*time.Second {
		t.Fatalf("expected API write timeout from env, got %s", cfg.Server.WriteTimeout)
	}
}

func TestLoad_UsesDefaultDatabasePath(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Database.Path != "data/privatedeploy.db" {
		t.Fatalf("expected default database path, got %q", cfg.Database.Path)
	}
}

func TestLoad_InvalidAPIWriteTimeoutReturnsError(t *testing.T) {
	t.Setenv("API_WRITE_TIMEOUT", "not-a-duration")

	_, err := Load()
	if err == nil {
		t.Fatal("expected error for invalid API write timeout")
	}
}
