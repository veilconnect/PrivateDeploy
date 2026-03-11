package bridge

import (
	"path/filepath"
	"testing"
)

func TestResolveBasePathUsesExecutableDirForPortableLinux(t *testing.T) {
	t.Setenv("HOME", "/home/tester")

	got := resolveBasePath("linux", "/home/tester/PrivateDeploy/privatedeploy")
	want := "/home/tester/PrivateDeploy"

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathUsesUserDataDirForSystemLinuxInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got := resolveBasePath("linux", "/usr/lib/privatedeploy/privatedeploy")
	want := filepath.Join(home, ".local", "share", "PrivateDeploy")

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathKeepsNonLinuxExecutableDir(t *testing.T) {
	got := resolveBasePath("darwin", "/Applications/PrivateDeploy.app/Contents/MacOS/PrivateDeploy")
	want := "/Applications/PrivateDeploy.app/Contents/MacOS"

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}
