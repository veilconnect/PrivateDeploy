package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func writeRestartExecutable(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%q): %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile(%q): %v", path, err)
	}
}

func TestRestartExecutablePrefersOriginalAppImage(t *testing.T) {
	dir := t.TempDir()
	appImage := filepath.Join(dir, "PrivateDeploy.AppImage")
	execPath := filepath.Join(dir, "mount", "usr", "bin", "privatedeploy")
	writeRestartExecutable(t, appImage)
	writeRestartExecutable(t, execPath)

	got, err := restartExecutable("linux", appImage, execPath)
	if err != nil {
		t.Fatalf("restartExecutable() error = %v", err)
	}
	if got != appImage {
		t.Fatalf("restartExecutable() = %q, want AppImage %q", got, appImage)
	}
}

func TestRestartExecutableRejectsUntrustedAppImagePaths(t *testing.T) {
	dir := t.TempDir()
	execPath := filepath.Join(dir, "PrivateDeploy")
	writeRestartExecutable(t, execPath)

	nonExecutable := filepath.Join(dir, "not-executable.AppImage")
	if err := os.WriteFile(nonExecutable, []byte("payload"), 0o644); err != nil {
		t.Fatalf("WriteFile(nonExecutable): %v", err)
	}

	realAppImage := filepath.Join(dir, "real.AppImage")
	writeRestartExecutable(t, realAppImage)
	symlinkAppImage := filepath.Join(dir, "symlink.AppImage")
	if err := os.Symlink(realAppImage, symlinkAppImage); err != nil {
		t.Fatalf("Symlink(): %v", err)
	}

	for _, candidate := range []string{"relative.AppImage", nonExecutable, symlinkAppImage, dir} {
		got, err := restartExecutable("linux", candidate, execPath)
		if err != nil {
			t.Fatalf("restartExecutable(%q) error = %v", candidate, err)
		}
		if got != execPath {
			t.Errorf("restartExecutable(%q) = %q, want fallback %q", candidate, got, execPath)
		}
	}
}

func TestRestartExecutableUsesLinuxCompatibilityWrapper(t *testing.T) {
	dir := t.TempDir()
	execPath := filepath.Join(dir, "PrivateDeploy.bin")
	wrapperPath := filepath.Join(dir, "PrivateDeploy")
	writeRestartExecutable(t, execPath)
	writeRestartExecutable(t, wrapperPath)

	got, err := restartExecutable("linux", "", execPath)
	if err != nil {
		t.Fatalf("restartExecutable() error = %v", err)
	}
	if got != wrapperPath {
		t.Fatalf("restartExecutable() = %q, want wrapper %q", got, wrapperPath)
	}
}

func TestRestartExecutableRejectsSymlinkedLinuxWrapper(t *testing.T) {
	dir := t.TempDir()
	execPath := filepath.Join(dir, "PrivateDeploy.bin")
	realWrapper := filepath.Join(dir, "real-wrapper")
	wrapperPath := filepath.Join(dir, "PrivateDeploy")
	writeRestartExecutable(t, execPath)
	writeRestartExecutable(t, realWrapper)
	if err := os.Symlink(realWrapper, wrapperPath); err != nil {
		t.Fatalf("Symlink(): %v", err)
	}

	got, err := restartExecutable("linux", "", execPath)
	if err != nil {
		t.Fatalf("restartExecutable() error = %v", err)
	}
	if got != execPath {
		t.Fatalf("restartExecutable() = %q, want raw fallback %q", got, execPath)
	}
}

func TestRestartExecutableRequiresFallback(t *testing.T) {
	if _, err := restartExecutable("linux", "relative.AppImage", ""); err == nil {
		t.Fatal("restartExecutable() error = nil, want empty fallback rejection")
	}
}
