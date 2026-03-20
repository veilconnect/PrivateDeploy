package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"privatedeploy/api/config"
	"privatedeploy/api/models"
)

func TestEnsureJWTSecret_DevelopmentGeneratesSecret(t *testing.T) {
	t.Setenv("API_ENV", "dev")

	cfg := &config.Config{}
	if err := ensureJWTSecret(cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.TrimSpace(cfg.JWT.Secret) == "" {
		t.Fatal("expected generated JWT secret")
	}
}

func TestEnsureJWTSecret_ProductionRequiresSecret(t *testing.T) {
	t.Setenv("API_ENV", "prod")

	cfg := &config.Config{}
	if err := ensureJWTSecret(cfg); err == nil {
		t.Fatal("expected error when JWT secret is missing outside development mode")
	}
}

func TestInitializeDefaultUser_RequiresPasswordOutsideDevelopmentMode(t *testing.T) {
	t.Setenv("API_ENV", "prod")

	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")
	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}

	if err := initializeDefaultUser(db, dbPath); err == nil {
		t.Fatal("expected bootstrap password requirement error")
	}
}

func TestInitializeDefaultUser_UsesPasswordFileOutsideDevelopmentMode(t *testing.T) {
	t.Setenv("API_ENV", "prod")

	passwordPath := filepath.Join(t.TempDir(), "admin-password.txt")
	if err := os.WriteFile(passwordPath, []byte("file-secret\n"), 0o600); err != nil {
		t.Fatalf("write password file: %v", err)
	}
	t.Setenv("INITIAL_ADMIN_PASSWORD_FILE", passwordPath)

	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")
	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}

	if err := initializeDefaultUser(db, dbPath); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var user models.User
	if err := db.Where("username = ?", "admin").First(&user).Error; err != nil {
		t.Fatalf("query bootstrap user: %v", err)
	}
	if strings.TrimSpace(user.Password) == "" {
		t.Fatal("expected hashed password to be stored")
	}

	bootstrapFile := filepath.Join(filepath.Dir(dbPath), "bootstrap-admin-password.txt")
	if _, err := os.Stat(bootstrapFile); !os.IsNotExist(err) {
		t.Fatalf("expected no generated bootstrap password file, got err=%v", err)
	}
}

func TestInitializeDefaultUser_DevelopmentWritesBootstrapPasswordFile(t *testing.T) {
	t.Setenv("API_ENV", "dev")

	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")
	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}

	if err := initializeDefaultUser(db, dbPath); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	passwordFile := filepath.Join(filepath.Dir(dbPath), "bootstrap-admin-password.txt")
	content, err := os.ReadFile(passwordFile)
	if err != nil {
		t.Fatalf("read generated password file: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, "username=admin\n") {
		t.Fatalf("expected username in bootstrap file, got %q", text)
	}
	if !strings.Contains(text, "password=") {
		t.Fatalf("expected password in bootstrap file, got %q", text)
	}
}
