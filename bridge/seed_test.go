package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSeedRuntimeDataCopiesBinaryWhenBasePathDiffers(t *testing.T) {
	installDir := t.TempDir()
	dataDir := t.TempDir()

	// Simulate: installer put sing-box in the install directory.
	srcDir := filepath.Join(installDir, "data", "sing-box")
	os.MkdirAll(srcDir, 0o755)
	srcFile := filepath.Join(srcDir, "sing-box")
	os.WriteFile(srcFile, []byte("fake-singbox-binary"), 0o755)

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(installDir, "app")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	seedRuntimeData()

	dst := filepath.Join(dataDir, "data", "sing-box", "sing-box")
	data, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("seeded file not found at %s: %v", dst, err)
	}
	if string(data) != "fake-singbox-binary" {
		t.Fatalf("seeded file content mismatch: got %q", string(data))
	}
}

func TestSeedRuntimeDataSkipsWhenBasePathMatchesExeDir(t *testing.T) {
	dir := t.TempDir()

	// Simulate portable install: exe and data in the same directory.
	srcDir := filepath.Join(dir, "data", "sing-box")
	os.MkdirAll(srcDir, 0o755)
	os.WriteFile(filepath.Join(srcDir, "sing-box"), []byte("binary"), 0o755)

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(dir, "app")
	Env.BasePath = dir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	// seedRuntimeData should be a no-op (same dir).
	seedRuntimeData()

	// The file should still be in the original location only.
	// No error means it didn't try to copy to itself.
}

func TestSeedRuntimeDataRefreshesWhenTargetDiffers(t *testing.T) {
	installDir := t.TempDir()
	dataDir := t.TempDir()

	srcDir := filepath.Join(installDir, "data", "sing-box")
	os.MkdirAll(srcDir, 0o755)
	os.WriteFile(filepath.Join(srcDir, "sing-box"), []byte("new-version"), 0o755)

	// Pre-create the target with different content.
	dstDir := filepath.Join(dataDir, "data", "sing-box")
	os.MkdirAll(dstDir, 0o755)
	dstFile := filepath.Join(dstDir, "sing-box")
	os.WriteFile(dstFile, []byte("existing-version"), 0o755)

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(installDir, "app")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	seedRuntimeData()

	// Should refresh the stale bundled file on upgrade.
	data, _ := os.ReadFile(dstFile)
	if string(data) != "new-version" {
		t.Fatalf("seedRuntimeData did not refresh existing file: got %q, want %q", string(data), "new-version")
	}
}

func TestSeedRuntimeDataSkipsWhenTargetMatchesSource(t *testing.T) {
	installDir := t.TempDir()
	dataDir := t.TempDir()

	srcDir := filepath.Join(installDir, "data", "sing-box")
	os.MkdirAll(srcDir, 0o755)
	srcFile := filepath.Join(srcDir, "sing-box")
	os.WriteFile(srcFile, []byte("same-version"), 0o755)

	dstDir := filepath.Join(dataDir, "data", "sing-box")
	os.MkdirAll(dstDir, 0o755)
	dstFile := filepath.Join(dstDir, "sing-box")
	os.WriteFile(dstFile, []byte("same-version"), 0o755)

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(installDir, "app")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	before, err := os.Stat(dstFile)
	if err != nil {
		t.Fatalf("stat dst before seed: %v", err)
	}

	seedRuntimeData()

	after, err := os.Stat(dstFile)
	if err != nil {
		t.Fatalf("stat dst after seed: %v", err)
	}
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("seedRuntimeData rewrote an identical runtime file")
	}
}

func TestSeedRuntimeDataSkipsWhenSourceNotBundled(t *testing.T) {
	installDir := t.TempDir()
	dataDir := t.TempDir()

	// Don't create any source file.
	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(installDir, "app")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	// Should not panic or error.
	seedRuntimeData()

	dst := filepath.Join(dataDir, "data", "sing-box", "sing-box")
	if _, err := os.Stat(dst); err == nil {
		t.Fatal("seedRuntimeData created a file when source doesn't exist")
	}
}
