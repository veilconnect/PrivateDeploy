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

func TestTrayExitMenuUsesBackendGracefulExit(t *testing.T) {
	called := false
	tray := &trayProc{
		exitApp: func() {
			called = true
		},
	}

	tray.createMenuItemLocked(MenuItem{
		Type:  "item",
		Text:  "Exit",
		Event: "17_tray.exit",
	}, &App{}, "")

	h, ok := tray.handlers.Load("id1")
	if !ok {
		t.Fatal("expected exit menu handler to be registered")
	}
	h.(func())()

	if !called {
		t.Fatal("expected tray exit menu to use backend graceful exit")
	}
}
