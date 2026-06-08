package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindSingboxBinaryFromEnvFindsExeInBasePath(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a fake sing-box binary at the expected path.
	singboxDir := filepath.Join(tmpDir, "data", "sing-box")
	os.MkdirAll(singboxDir, 0o755)

	singboxBin := filepath.Join(singboxDir, "sing-box")
	os.WriteFile(singboxBin, []byte("fake"), 0o755)

	origBasePath := Env.BasePath
	Env.BasePath = tmpDir
	defer func() { Env.BasePath = origBasePath }()

	got := findSingboxBinaryFromEnv()
	if got != singboxBin {
		t.Fatalf("findSingboxBinaryFromEnv() = %q, want %q", got, singboxBin)
	}
}

func TestFindSingboxBinaryFromEnvFallsBackToLatest(t *testing.T) {
	tmpDir := t.TempDir()

	singboxDir := filepath.Join(tmpDir, "data", "sing-box")
	os.MkdirAll(singboxDir, 0o755)

	// Only create "sing-box-latest", not "sing-box".
	latestBin := filepath.Join(singboxDir, "sing-box-latest")
	os.WriteFile(latestBin, []byte("fake"), 0o755)

	origBasePath := Env.BasePath
	Env.BasePath = tmpDir
	defer func() { Env.BasePath = origBasePath }()

	got := findSingboxBinaryFromEnv()
	if got != latestBin {
		t.Fatalf("findSingboxBinaryFromEnv() = %q, want %q", got, latestBin)
	}
}

func TestFindSingboxBinaryFromEnvRespectsEnvVar(t *testing.T) {
	tmpDir := t.TempDir()
	customPath := filepath.Join(tmpDir, "my-sing-box")
	os.WriteFile(customPath, []byte("fake"), 0o755)

	t.Setenv("PRIVATEDEPLOY_SINGBOX_PATH", customPath)

	origBasePath := Env.BasePath
	Env.BasePath = "/nonexistent"
	defer func() { Env.BasePath = origBasePath }()

	got := findSingboxBinaryFromEnv()
	if got != customPath {
		t.Fatalf("findSingboxBinaryFromEnv() = %q, want %q", got, customPath)
	}
}

func TestFindSingboxBinaryFromEnvReturnsEmptyWhenNotFound(t *testing.T) {
	tmpDir := t.TempDir()

	origBasePath := Env.BasePath
	Env.BasePath = tmpDir
	defer func() { Env.BasePath = origBasePath }()

	// Ensure PRIVATEDEPLOY_SINGBOX_PATH is not set.
	t.Setenv("PRIVATEDEPLOY_SINGBOX_PATH", "")

	got := findSingboxBinaryFromEnv()
	// sing-box may or may not be on PATH; just ensure it doesn't panic
	// and returns a valid result.
	if got != "" {
		// If it found something, it must be from LookPath.
		if _, err := os.Stat(got); err != nil {
			t.Fatalf("findSingboxBinaryFromEnv() returned %q but file doesn't exist", got)
		}
	}
}
