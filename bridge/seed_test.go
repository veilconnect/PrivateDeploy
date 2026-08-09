package bridge

import (
	"os"
	"path/filepath"
	"runtime"
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

func TestSeedRuntimeDataCopiesFromAppImageLayout(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("AppImage layout is Linux-only")
	}

	appDir := t.TempDir()
	dataDir := t.TempDir()
	exeDir := filepath.Join(appDir, "usr", "bin")
	srcDir := filepath.Join(appDir, "usr", "lib", "privatedeploy", "data", "sing-box")
	if err := os.MkdirAll(exeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(srcDir, 0o755); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(srcDir, "sing-box")
	if err := os.WriteFile(src, []byte("appimage-singbox"), 0o755); err != nil {
		t.Fatal(err)
	}

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(exeDir, "privatedeploy")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	seedRuntimeData()

	dst := filepath.Join(dataDir, "data", "sing-box", "sing-box")
	content, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read AppImage-seeded core: %v", err)
	}
	if string(content) != "appimage-singbox" {
		t.Fatalf("AppImage-seeded core = %q", content)
	}
	info, err := os.Stat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("AppImage-seeded core mode = %o, want executable", info.Mode().Perm())
	}
}

func TestSeedRuntimeDataPrefersPortableLayoutOverAppImageFallback(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux runtime candidate ordering")
	}

	appDir := t.TempDir()
	dataDir := t.TempDir()
	exeDir := filepath.Join(appDir, "usr", "bin")
	portable := filepath.Join(exeDir, "data", "sing-box", "sing-box")
	appImage := filepath.Join(appDir, "usr", "lib", "privatedeploy", "data", "sing-box", "sing-box")
	for path, content := range map[string]string{
		portable: "portable-first",
		appImage: "appimage-second",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	origExecPath := Env.ExecPath
	origBasePath := Env.BasePath
	Env.ExecPath = filepath.Join(exeDir, "privatedeploy")
	Env.BasePath = dataDir
	defer func() {
		Env.ExecPath = origExecPath
		Env.BasePath = origBasePath
	}()

	seedRuntimeData()
	dst := filepath.Join(dataDir, "data", "sing-box", "sing-box")
	content, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "portable-first" {
		t.Fatalf("seeded candidate = %q, want portable layout first", content)
	}
}

func TestSeedRuntimeDataRejectsSymlinkAndNonExecutableSources(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("POSIX executable and symlink policy")
	}

	for _, test := range []struct {
		name  string
		setup func(t *testing.T, source string)
	}{
		{
			name: "symlink",
			setup: func(t *testing.T, source string) {
				realSource := filepath.Join(filepath.Dir(source), "real-sing-box")
				if err := os.WriteFile(realSource, []byte("untrusted-link-target"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(realSource, source); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "non-executable",
			setup: func(t *testing.T, source string) {
				if err := os.WriteFile(source, []byte("non-executable"), 0o644); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			installDir := t.TempDir()
			dataDir := t.TempDir()
			source := filepath.Join(installDir, "data", "sing-box", "sing-box")
			if err := os.MkdirAll(filepath.Dir(source), 0o755); err != nil {
				t.Fatal(err)
			}
			test.setup(t, source)

			dst := filepath.Join(dataDir, "data", "sing-box", "sing-box")
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(dst, []byte("known-good-old-core"), 0o755); err != nil {
				t.Fatal(err)
			}

			origExecPath := Env.ExecPath
			origBasePath := Env.BasePath
			Env.ExecPath = filepath.Join(installDir, "app")
			Env.BasePath = dataDir
			defer func() {
				Env.ExecPath = origExecPath
				Env.BasePath = origBasePath
			}()

			seedRuntimeData()
			content, err := os.ReadFile(dst)
			if err != nil {
				t.Fatal(err)
			}
			if string(content) != "known-good-old-core" {
				t.Fatalf("failed seed changed previous core to %q", content)
			}
		})
	}
}

func TestCopyFileAtomicRejectsNonRegularDestination(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("POSIX symlink policy")
	}

	source := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(source, []byte("new-core"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		outside := filepath.Join(dir, "outside-core")
		if err := os.WriteFile(outside, []byte("outside-old"), 0o755); err != nil {
			t.Fatal(err)
		}
		dst := filepath.Join(dir, "sing-box")
		if err := os.Symlink(outside, dst); err != nil {
			t.Fatal(err)
		}
		if err := copyFileAtomic(source, dst, 0o755); err == nil {
			t.Fatal("copyFileAtomic accepted a symlink destination")
		}
		content, err := os.ReadFile(outside)
		if err != nil {
			t.Fatal(err)
		}
		if string(content) != "outside-old" {
			t.Fatalf("symlink target changed to %q", content)
		}
		if info, err := os.Lstat(dst); err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("destination symlink was replaced: info=%v err=%v", info, err)
		}
	})

	t.Run("directory", func(t *testing.T) {
		dst := filepath.Join(t.TempDir(), "sing-box")
		if err := os.Mkdir(dst, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := copyFileAtomic(source, dst, 0o755); err == nil {
			t.Fatal("copyFileAtomic accepted a directory destination")
		}
		if info, err := os.Stat(dst); err != nil || !info.IsDir() {
			t.Fatalf("destination directory was replaced: info=%v err=%v", info, err)
		}
	})
}
