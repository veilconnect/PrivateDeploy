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
			sshConnection: "192.168.10.12 43210 192.168.10.16 22",
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
