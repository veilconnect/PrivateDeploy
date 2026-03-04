package main

import (
	"context"
	"embed"
	"os"
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
	err := wails.Run(&options.App{
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
		println("Error:", err.Error())
	}
}
