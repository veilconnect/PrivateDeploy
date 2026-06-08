package main

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
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

func TestDetectUnsupportedLinuxRemoteDisplay(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		display       string
		wayland       string
		sshConnection string
		xdpyinfo      string
		xrandr        string
		wantReason    string
		wantBlocked   bool
	}{
		{
			name:        "local x11 display is allowed",
			display:     ":0",
			xdpyinfo:    "vendor string: The X.Org Foundation",
			xrandr:      "HDMI-1 connected",
			wantBlocked: false,
		},
		{
			name:          "x11 forwarding is blocked",
			display:       "localhost:10.0",
			sshConnection: "192.0.2.12 43210 192.0.2.16 22",
			wantReason:    "Remote Linux X11 forwarding is not supported by this build because WebKitGTK renders blank windows in forwarded sessions.",
			wantBlocked:   true,
		},
		{
			name:        "vnc x server is blocked via xdpyinfo",
			display:     ":1",
			xdpyinfo:    "vendor string: The X.Org Foundation\n    VNC-EXTENSION\n",
			wantReason:  "Remote Linux VNC desktops are not supported by this build because WebKitGTK renders blank windows in VNC sessions.",
			wantBlocked: true,
		},
		{
			name:        "vnc x server is blocked via xrandr",
			display:     ":1",
			xrandr:      "VNC-0 connected 1600x1000+0+0",
			wantReason:  "Remote Linux VNC desktops are not supported by this build because WebKitGTK renders blank windows in VNC sessions.",
			wantBlocked: true,
		},
		{
			name:        "wayland sessions are allowed",
			display:     "",
			wayland:     "wayland-0",
			wantBlocked: false,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			gotReason, gotBlocked := detectUnsupportedLinuxRemoteDisplay(
				tc.display,
				tc.wayland,
				tc.sshConnection,
				tc.xdpyinfo,
				tc.xrandr,
			)

			if gotBlocked != tc.wantBlocked {
				t.Fatalf("blocked = %v, want %v", gotBlocked, tc.wantBlocked)
			}
			if gotReason != tc.wantReason {
				t.Fatalf("reason = %q, want %q", gotReason, tc.wantReason)
			}
		})
	}
}

func TestCleanWebView2LocksIn_RemovesLockFilesAndKeepsOthers(t *testing.T) {
	root := t.TempDir()

	// Files we expect to be removed (top-level + nested).
	want := []string{
		filepath.Join(root, "SingletonLock"),
		filepath.Join(root, "SingletonCookie"),
		filepath.Join(root, "EBWebView", "Default", "lockfile"),
		filepath.Join(root, "EBWebView", "Default", "Cache", "LOCK"),
	}
	// Files that must NOT be removed.
	keep := []string{
		filepath.Join(root, "Preferences"),
		filepath.Join(root, "EBWebView", "Default", "Preferences"),
		filepath.Join(root, "EBWebView", "Default", "Cookies"),
	}

	for _, p := range append(append([]string{}, want...), keep...) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", filepath.Dir(p), err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}

	got := cleanWebView2LocksIn(root)
	if got != len(want) {
		t.Fatalf("cleanWebView2LocksIn returned %d, want %d", got, len(want))
	}
	for _, p := range want {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("expected lock %q to be removed, stat err = %v", p, err)
		}
	}
	for _, p := range keep {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("expected non-lock %q to be retained, stat err = %v", p, err)
		}
	}
}

func TestCleanWebView2LocksIn_MissingFolderIsNoop(t *testing.T) {
	if got := cleanWebView2LocksIn(filepath.Join(t.TempDir(), "does-not-exist")); got != 0 {
		t.Fatalf("expected 0 cleaned for missing folder, got %d", got)
	}
	if got := cleanWebView2LocksIn(""); got != 0 {
		t.Fatalf("expected 0 cleaned for empty path, got %d", got)
	}
}

func TestCleanWebView2LocksIn_FileTargetIsNoop(t *testing.T) {
	// If the candidate path turns out to be a regular file (corrupt or odd
	// install layout), we should not panic or treat it as a folder.
	dir := t.TempDir()
	regular := filepath.Join(dir, "PrivateDeploy.WebView2")
	if err := os.WriteFile(regular, []byte("x"), 0o644); err != nil {
		t.Fatalf("write %s: %v", regular, err)
	}
	if got := cleanWebView2LocksIn(regular); got != 0 {
		t.Fatalf("expected 0 cleaned for file target, got %d", got)
	}
	if _, err := os.Stat(regular); err != nil {
		t.Fatalf("regular file should be untouched: %v", err)
	}
}

func TestIsInstallerQuitRequest(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want bool
	}{
		{name: "empty args", args: nil, want: false},
		{name: "regular launch", args: []string{"PrivateDeploy.exe"}, want: false},
		{name: "installer quit flag only", args: []string{installerQuitArg}, want: true},
		{name: "installer quit flag after exe path", args: []string{"PrivateDeploy.exe", installerQuitArg}, want: true},
		{name: "similar flag is ignored", args: []string{"PrivateDeploy.exe", installerQuitArg + "=1"}, want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := isInstallerQuitRequest(tc.args); got != tc.want {
				t.Fatalf("isInstallerQuitRequest(%v) = %v, want %v", tc.args, got, tc.want)
			}
		})
	}
}

func TestWebView2UserDataCandidates_HonorsExplicitEnv(t *testing.T) {
	t.Setenv("WEBVIEW2_USER_DATA_FOLDER", filepath.Join(t.TempDir(), "explicit-wv2"))
	got := webView2UserDataCandidates()
	if len(got) == 0 || got[0] != os.Getenv("WEBVIEW2_USER_DATA_FOLDER") {
		t.Fatalf("explicit env should appear first; got %v", got)
	}
}

// failingWriter mimics a broken handle (e.g., a Windows stderr without a
// console attached) by always returning an error.
type failingWriter struct{ err error }

func (f *failingWriter) Write(p []byte) (int, error) { return 0, f.err }

func TestIsolatedFanoutWriter_FailingWriterDoesNotSuppressOthers(t *testing.T) {
	good := &bytes.Buffer{}
	bad := &failingWriter{err: errors.New("no console")}

	w := &isolatedFanoutWriter{writers: []io.Writer{bad, good}}
	payload := []byte("startup line\n")
	n, err := w.Write(payload)
	if err != nil {
		t.Fatalf("isolatedFanoutWriter should swallow per-writer errors, got %v", err)
	}
	if n != len(payload) {
		t.Fatalf("returned n = %d, want %d", n, len(payload))
	}
	if got := good.String(); got != string(payload) {
		t.Fatalf("good writer received %q, want %q", got, string(payload))
	}
}

func TestIsolatedFanoutWriter_AllWritersReceiveSamePayload(t *testing.T) {
	a, b, c := &bytes.Buffer{}, &bytes.Buffer{}, &bytes.Buffer{}
	w := &isolatedFanoutWriter{writers: []io.Writer{a, b, c}}
	payloads := []string{"one\n", "two\n", "three\n"}
	for _, p := range payloads {
		if _, err := w.Write([]byte(p)); err != nil {
			t.Fatalf("write %q: %v", p, err)
		}
	}
	expected := strings.Join(payloads, "")
	for name, buf := range map[string]*bytes.Buffer{"a": a, "b": b, "c": c} {
		if got := buf.String(); got != expected {
			t.Errorf("writer %s got %q, want %q", name, got, expected)
		}
	}
}
