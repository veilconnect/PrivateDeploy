package bridge

import "testing"

func TestTrayRightClickExitsOnLinuxAndWindows(t *testing.T) {
	origOS := Env.OS
	t.Cleanup(func() { Env.OS = origOS })

	for _, osName := range []string{"linux", "windows"} {
		t.Run(osName, func(t *testing.T) {
			Env.OS = osName
			called := false
			tray := &trayProc{
				exitApp: func() {
					called = true
				},
			}

			tray.handleTrayRightClick()

			if !called {
				t.Fatalf("expected tray right-click to exit on %s", osName)
			}
		})
	}
}

func TestTrayRightClickDoesNotExitOnDarwin(t *testing.T) {
	origOS := Env.OS
	t.Cleanup(func() { Env.OS = origOS })

	Env.OS = "darwin"
	called := false
	tray := &trayProc{
		exitApp: func() {
			called = true
		},
	}

	tray.handleTrayRightClick()

	if called {
		t.Fatal("expected tray right-click to leave macOS menu behavior unchanged")
	}
}

func TestTraySidecarNameUsesWindowsExecutableExtension(t *testing.T) {
	if got := traySidecarName("windows"); got != "privatedeploy-tray.exe" {
		t.Fatalf("windows sidecar name = %q", got)
	}
	if got := traySidecarName("linux"); got != "privatedeploy-tray" {
		t.Fatalf("linux sidecar name = %q", got)
	}
}
