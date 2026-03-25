package main

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/logger"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed frontend/dist/favicon.ico
var icon []byte

//go:embed frontend/dist/imgs/tray_normal_dark.png
var linuxTrayIcon []byte

func main() {
	if err := validateLinuxDisplay(); err != nil {
		fmt.Fprintln(os.Stderr, formatStartupError(err))
		os.Exit(1)
	}

	linuxMinimalShell := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_LINUX_MINIMAL_SHELL") == "1"

	appIcon := icon
	if bridge.Env.OS == "linux" && len(linuxTrayIcon) > 0 {
		// GTK-based Linux desktop stacks decode PNG icons reliably.
		appIcon = linuxTrayIcon
	}

	frontendAssets, err := fs.Sub(assets, "frontend/dist")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to mount embedded frontend assets: %v\n", err)
		os.Exit(1)
	}

	app := bridge.CreateApp(assets)
	trayStart := func() {}
	if !linuxMinimalShell && os.Getenv("PRIVATEDEPLOY_DISABLE_TRAY") != "1" {
		trayStart, _ = bridge.CreateTray(app, appIcon)
	}

	appMenu := app.AppMenu
	windowWidth := bridge.Config.Width
	windowHeight := bridge.Config.Height
	startHidden := bridge.Config.StartHidden
	windowStartState := options.WindowStartState(bridge.Config.WindowStartState)
	singleInstanceLock := &options.SingleInstanceLock{
		UniqueId: func() string {
			if bridge.Config.MultipleInstance {
				return time.Now().String()
			}
			return bridge.Env.AppName
		}(),
		OnSecondInstanceLaunch: func(data options.SecondInstanceData) {
			runtime.Show(app.Ctx)
			runtime.EventsEmit(app.Ctx, "onLaunchApp", data.Args)
		},
	}

	if linuxMinimalShell {
		appMenu = nil
		windowWidth = 1280
		windowHeight = 840
		startHidden = false
		windowStartState = options.Normal
		singleInstanceLock = nil
	}

	// Create application with options
	isWindows := bridge.Env.OS == "windows"

	err = runWailsWithRecovery(&options.App{
		MinWidth:         600,
		MinHeight:        400,
		DisableResize:    false,
		Menu:             appMenu,
		Title:            bridge.Env.AppName,
		Frameless:        isWindows,
		Width:            windowWidth,
		Height:           windowHeight,
		StartHidden:      startHidden,
		WindowStartState: windowStartState,
		BackgroundColour: &options.RGBA{R: 255, G: 255, B: 255, A: 255},
		Windows: &windows.Options{
			// Keep the Windows shell fully opaque. Transparent WebView2 + acrylic
			// looks appealing on local desktops but renders as black/ghosted UI
			// on Windows Server and many RDP sessions.
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			BackdropType:         windows.None,
		},
		Mac: &mac.Options{
			TitleBar:             mac.TitleBarHiddenInset(),
			Appearance:           mac.DefaultAppearance,
			WebviewIsTransparent: true,
			WindowIsTranslucent:  true,
			About: &mac.AboutInfo{
				Title:   bridge.Env.AppName,
				Message: "© 2025 PrivateDeploy",
				Icon:    icon,
			},
		},
		Linux: &linux.Options{
			Icon:                appIcon,
			WindowIsTranslucent: false,
			ProgramName:         bridge.Env.AppName,
			WebviewGpuPolicy:    linux.WebviewGpuPolicy(bridge.Config.WebviewGpuPolicy),
		},
		AssetServer: &assetserver.Options{
			Assets:     frontendAssets,
			Middleware: bridge.RollingRelease,
		},
		SingleInstanceLock: singleInstanceLock,
		OnStartup: func(ctx context.Context) {
			app.Ctx = ctx
			if !linuxMinimalShell {
				trayStart()
			}
			app.SetupSSHEventEmitter()
		},
		OnDomReady: func(ctx context.Context) {
			if bridge.Env.OS != "linux" || linuxMinimalShell {
				return
			}

			go func() {
				time.Sleep(200 * time.Millisecond)
				runtime.Show(ctx)
				runtime.WindowShow(ctx)
				runtime.WindowUnminimise(ctx)
				time.Sleep(250 * time.Millisecond)
				runtime.Show(ctx)
				runtime.WindowShow(ctx)
				runtime.WindowUnminimise(ctx)
			}()
		},
		OnBeforeClose: func(ctx context.Context) (prevent bool) {
			runtime.EventsEmit(ctx, "onBeforeExitApp")
			return true
		},
		Bind: []any{
			app,
		},
		LogLevel: logger.INFO,
		Debug: options.Debug{
			OpenInspectorOnStartup: false,
		},
	})

	if err != nil {
		fmt.Fprintln(os.Stderr, formatStartupError(err))
		os.Exit(1)
	}
}

func runWailsWithRecovery(appOptions *options.App) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("desktop runtime panic: %v", recovered)
		}
	}()

	return wails.Run(appOptions)
}

func validateLinuxDisplay() error {
	if bridge.Env.OS != "linux" || os.Getenv("PRIVATEDEPLOY_SKIP_DISPLAY_CHECK") == "1" {
		return nil
	}

	display := strings.TrimSpace(os.Getenv("DISPLAY"))
	waylandDisplay := strings.TrimSpace(os.Getenv("WAYLAND_DISPLAY"))

	if display == "" && waylandDisplay == "" {
		return fmt.Errorf("no GUI display detected (DISPLAY/WAYLAND_DISPLAY are both empty)")
	}

	if waylandDisplay != "" {
		if runtimeDir := strings.TrimSpace(os.Getenv("XDG_RUNTIME_DIR")); runtimeDir != "" {
			waylandSocket := filepath.Join(runtimeDir, waylandDisplay)
			if _, err := os.Stat(waylandSocket); err != nil {
				return fmt.Errorf("WAYLAND_DISPLAY=%q is not reachable at %s", waylandDisplay, waylandSocket)
			}
		}
	}

	if display == "" {
		return nil
	}

	xAuthority := ensureXAuthorityEnv()

	if socketPath := x11SocketPath(display); socketPath != "" {
		conn, err := net.DialTimeout("unix", socketPath, 1200*time.Millisecond)
		if err != nil {
			return fmt.Errorf("X11 socket %q is not accessible for DISPLAY=%q: %v", socketPath, display, err)
		}
		_ = conn.Close()
	}

	if _, err := exec.LookPath("xdpyinfo"); err != nil {
		return nil
	}

	cmd := exec.Command("xdpyinfo")
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
	if xAuthority != "" {
		cmd.Env = append(cmd.Env, "XAUTHORITY="+xAuthority)
	}
	if output, err := cmd.CombinedOutput(); err != nil {
		detail := strings.TrimSpace(string(output))
		if detail == "" {
			detail = err.Error()
		}
		if len(detail) > 160 {
			detail = detail[:160] + "..."
		}
		return fmt.Errorf("X11 display %q is not accessible: %s", display, detail)
	}

	return nil
}

func ensureXAuthorityEnv() string {
	if value := strings.TrimSpace(os.Getenv("XAUTHORITY")); value != "" {
		return value
	}

	homeDir := strings.TrimSpace(os.Getenv("HOME"))
	if homeDir == "" {
		return ""
	}

	candidate := filepath.Join(homeDir, ".Xauthority")
	if _, err := os.Stat(candidate); err != nil {
		return ""
	}

	_ = os.Setenv("XAUTHORITY", candidate)
	return candidate
}

func x11SocketPath(display string) string {
	trimmed := strings.TrimSpace(display)
	if !strings.HasPrefix(trimmed, ":") {
		return ""
	}

	remainder := strings.TrimPrefix(trimmed, ":")
	screen := strings.SplitN(remainder, ".", 2)[0]
	if screen == "" {
		return ""
	}
	if _, err := strconv.Atoi(screen); err != nil {
		return ""
	}
	return "/tmp/.X11-unix/X" + screen
}

func formatStartupError(err error) string {
	if bridge.Env.OS != "linux" {
		return "Error: " + err.Error()
	}

	message := err.Error()
	if strings.Contains(message, "failed to init GTK") || strings.Contains(message, "X11 display") || strings.Contains(message, "X11 socket") || strings.Contains(message, "desktop runtime panic") || strings.Contains(message, "no GUI display detected") || strings.Contains(message, "WAYLAND_DISPLAY") {
		return fmt.Sprintf(
			"Error: %s\nLinux GUI startup check failed. Current DISPLAY=%q WAYLAND_DISPLAY=%q.\nPlease launch from a desktop terminal with a valid display session.",
			err.Error(),
			os.Getenv("DISPLAY"),
			os.Getenv("WAYLAND_DISPLAY"),
		)
	}

	return "Error: " + err.Error()
}
