package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExportCloudBackupUsesEnvPath(t *testing.T) {
	t.Setenv(dialogSavePathEnv, filepath.Join(t.TempDir(), "backup.json"))

	app := &App{}
	path, err := app.ExportCloudBackup(`{"hello":"world"}`)
	if err != nil {
		t.Fatalf("ExportCloudBackup() error = %v", err)
	}
	if path == "" {
		t.Fatal("ExportCloudBackup() returned empty path")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("os.ReadFile(%q) error = %v", path, err)
	}
	if string(data) != `{"hello":"world"}` {
		t.Fatalf("ExportCloudBackup() wrote %q", string(data))
	}
}

func TestImportCloudBackupUsesEnvPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.json")
	if err := os.WriteFile(path, []byte(`{"import":true}`), 0o600); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}
	t.Setenv(dialogOpenPathEnv, path)

	app := &App{}
	content, err := app.ImportCloudBackup()
	if err != nil {
		t.Fatalf("ImportCloudBackup() error = %v", err)
	}
	if content != `{"import":true}` {
		t.Fatalf("ImportCloudBackup() = %q", content)
	}
}

func TestImportCloudBackupReturnsEmptyOnBlankEnv(t *testing.T) {
	t.Setenv(dialogOpenPathEnv, "")

	app := &App{}
	_, err := app.ImportCloudBackup()
	if err == nil {
		t.Fatal("ImportCloudBackup() expected context error when no env override is set")
	}
}
