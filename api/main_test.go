package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetupDatabase_CreatesParentDirectoryAndFile(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "nested", "data", "privatedeploy.db")

	db, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("setup database: %v", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("extract sql DB: %v", err)
	}
	defer sqlDB.Close()

	if err := db.Exec("SELECT 1").Error; err != nil {
		t.Fatalf("ping sqlite database: %v", err)
	}

	if _, err := os.Stat(filepath.Dir(dbPath)); err != nil {
		t.Fatalf("expected database directory to exist: %v", err)
	}
	if _, err := os.Stat(dbPath); err != nil {
		t.Fatalf("expected database file to exist: %v", err)
	}
}

func TestSetupDatabase_CanReuseExistingDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "data", "privatedeploy.db")

	firstDB, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("first setup database: %v", err)
	}
	firstSQLDB, err := firstDB.DB()
	if err != nil {
		t.Fatalf("first sql DB: %v", err)
	}
	firstSQLDB.Close()

	secondDB, err := setupDatabase(dbPath)
	if err != nil {
		t.Fatalf("second setup database: %v", err)
	}
	secondSQLDB, err := secondDB.DB()
	if err != nil {
		t.Fatalf("second sql DB: %v", err)
	}
	defer secondSQLDB.Close()

	if err := secondDB.Exec("SELECT 1").Error; err != nil {
		t.Fatalf("query reopened database: %v", err)
	}
}
