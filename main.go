package main

import (
	"context"
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

	appIcon := icon
	if bridge.Env.OS == "linux" && len(linuxTrayIcon) > 0 {
		// GTK-based Linux desktop stacks decode PNG icons reliably.
		appIcon = linuxTrayIcon
	}

	app := bridge.CreateApp(assets)
	trayStart := func() {}
	if os.Getenv("PRIVATEDEPLOY_DISABLE_TRAY") != "1" {
		trayStart, _ = bridge.CreateTray(app, appIcon)
	}

	// Create application with options
	err := runWailsWithRecovery(&options.App{
		MinWidth:         600,
		MinHeight:        400,
		DisableResize:    false,
		Menu:             app.AppMenu,
		Title:            bridge.Env.AppName,
		Frameless:        bridge.Env.OS == "windows",
		Width:            bridge.Config.Width,
		Height:           bridge.Config.Height,
		StartHidden:      bridge.Config.StartHidden,
		WindowStartState: options.WindowStartState(bridge.Config.WindowStartState),
		BackgroundColour: &options.RGBA{R: 255, G: 255, B: 255, A: 1},
		Windows: &windows.Options{
			WebviewIsTransparent: true,
			WindowIsTranslucent:  true,
			BackdropType:         windows.Acrylic,
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
			Assets:     assets,
			Middleware: bridge.RollingRelease,
		},
		SingleInstanceLock: &options.SingleInstanceLock{
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
		},
		OnStartup: func(ctx context.Context) {
			app.Ctx = ctx
			trayStart()
			app.SetupSSHEventEmitter()
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

	if _, err := exec.LookPath("xdpyinfo"); err != nil {
		return nil
	}

	cmd := exec.Command("xdpyinfo")
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
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

func formatStartupError(err error) string {
	if bridge.Env.OS != "linux" {
		return "Error: " + err.Error()
	}

	message := err.Error()
	if strings.Contains(message, "failed to init GTK") || strings.Contains(message, "X11 display") || strings.Contains(message, "desktop runtime panic") || strings.Contains(message, "no GUI display detected") || strings.Contains(message, "WAYLAND_DISPLAY") {
		return fmt.Sprintf(
			"Error: %s\nLinux GUI startup check failed. Current DISPLAY=%q WAYLAND_DISPLAY=%q.\nPlease launch from a desktop terminal with a valid display session.",
			err.Error(),
			os.Getenv("DISPLAY"),
			os.Getenv("WAYLAND_DISPLAY"),
		)
	}

	return "Error: " + err.Error()
}
