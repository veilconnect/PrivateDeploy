package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureXAuthorityEnv_PreservesExplicitEnv(t *testing.T) {
	t.Setenv("XAUTHORITY", "/tmp/custom-xauthority")
	t.Setenv("HOME", t.TempDir())

	got := ensureXAuthorityEnv()
	if got != "/tmp/custom-xauthority" {
		t.Fatalf("expected explicit XAUTHORITY to win, got %q", got)
	}
}

func TestEnsureXAuthorityEnv_FallsBackToHomeXauthority(t *testing.T) {
	homeDir := t.TempDir()
	xauthPath := filepath.Join(homeDir, ".Xauthority")
	if err := os.WriteFile(xauthPath, []byte("cookie"), 0o600); err != nil {
		t.Fatalf("write .Xauthority: %v", err)
	}

	t.Setenv("XAUTHORITY", "")
	t.Setenv("HOME", homeDir)

	got := ensureXAuthorityEnv()
	if got != xauthPath {
		t.Fatalf("expected fallback XAUTHORITY %q, got %q", xauthPath, got)
	}
	if env := os.Getenv("XAUTHORITY"); env != xauthPath {
		t.Fatalf("expected XAUTHORITY env to be set to %q, got %q", xauthPath, env)
	}
}

func TestEmbeddedFrontendAssetsExposeIndexHTMLAtRoot(t *testing.T) {
	frontendAssets, err := fs.Sub(assets, "frontend/dist")
	if err != nil {
		t.Fatalf("fs.Sub(assets, %q) error = %v", "frontend/dist", err)
	}

	data, err := fs.ReadFile(frontendAssets, "index.html")
	if err != nil {
		t.Fatalf("fs.ReadFile(index.html) error = %v", err)
	}
	if len(data) == 0 {
		t.Fatal("embedded index.html is empty")
	}
}
