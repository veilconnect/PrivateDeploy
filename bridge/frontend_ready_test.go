package bridge

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSignalFrontendReadyIsNoopWithoutInstallerChallenge(t *testing.T) {
	t.Setenv(frontendReadyFileEnv, "")
	t.Setenv(frontendReadyNonceEnv, "")
	t.Setenv(frontendReadyTitleEnv, "")

	if err := (&App{}).SignalFrontendReady(); err != nil {
		t.Fatalf("SignalFrontendReady() error = %v", err)
	}
}

func TestSignalFrontendReadyWritesPIDAndNonce(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "ready.state")
	nonce := "0123456789abcdef0123456789abcdef"
	t.Setenv(frontendReadyFileEnv, statePath)
	t.Setenv(frontendReadyNonceEnv, nonce)
	t.Setenv(frontendReadyTitleEnv, "")

	if err := (&App{}).SignalFrontendReady(); err != nil {
		t.Fatalf("SignalFrontendReady() error = %v", err)
	}

	contents, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	state := string(contents)
	if !strings.Contains(state, "pid="+strconv.Itoa(os.Getpid())+"\n") {
		t.Fatalf("state does not contain current PID: %q", state)
	}
	if !strings.Contains(state, "nonce="+nonce+"\n") {
		t.Fatalf("state does not contain challenge nonce: %q", state)
	}
	info, err := os.Stat(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("state mode = %#o, want 0600", got)
	}
}

func TestSignalFrontendReadyRejectsInvalidChallenge(t *testing.T) {
	tests := []struct {
		name  string
		path  string
		nonce string
	}{
		{name: "relative path", path: "ready.state", nonce: "0123456789abcdef"},
		{name: "short nonce", path: filepath.Join(t.TempDir(), "ready.state"), nonce: "short"},
		{name: "newline nonce", path: filepath.Join(t.TempDir(), "ready.state"), nonce: "0123456789abcde\n"},
		{name: "missing nonce", path: filepath.Join(t.TempDir(), "ready.state")},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv(frontendReadyFileEnv, test.path)
			t.Setenv(frontendReadyNonceEnv, test.nonce)
			t.Setenv(frontendReadyTitleEnv, "")
			if err := (&App{}).SignalFrontendReady(); err == nil {
				t.Fatal("SignalFrontendReady() accepted invalid challenge")
			}
		})
	}
}

func TestWriteFrontendReadyStateAtomicallyReplacesSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("creating and atomically replacing symlinks requires extra Windows privileges")
	}
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim")
	statePath := filepath.Join(dir, "ready.state")
	if err := os.WriteFile(victim, []byte("do not overwrite"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, statePath); err != nil {
		t.Fatal(err)
	}

	if err := writeFrontendReadyState(statePath, 1234, "0123456789abcdef", time.Unix(1, 2).UTC()); err != nil {
		t.Fatal(err)
	}
	victimContents, err := os.ReadFile(victim)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(victimContents); got != "do not overwrite" {
		t.Fatalf("symlink target was overwritten: %q", got)
	}
	info, err := os.Lstat(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("ready state remained a symlink")
	}
}
