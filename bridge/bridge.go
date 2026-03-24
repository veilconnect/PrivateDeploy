package bridge

import (
	"context"
	"embed"
	"log"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"time"

	sysruntime "runtime"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"privatedeploy/bridge/cloud/health"
	filesystem "privatedeploy/bridge/services/filesystem"

	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/runtime"
	"gopkg.in/yaml.v3"
)

var Config = &AppConfig{}

const (
	webviewGpuPolicyAlways   = 0
	webviewGpuPolicyOnDemand = 1
	webviewGpuPolicyNever    = 2
)

var Env = &EnvResult{
	IsStartup:    true,
	FromTaskSch:  false,
	ExecPath:     "",
	AppName:      "",
	AppVersion:   "v1.10.1",
	BasePath:     "",
	OS:           sysruntime.GOOS,
	ARCH:         sysruntime.GOARCH,
	Capabilities: buildPlatformCapabilities(sysruntime.GOOS),
}

// NewApp creates a new App application struct
func NewApp() *App {
	return &App{
		AppMenu: menu.NewMenu(),
	}
}

func CreateApp(fs embed.FS) *App {
	exePath, err := os.Executable()
	if err != nil {
		panic(err)
	}

	Env.ExecPath = exePath
	Env.BasePath = resolveBasePath(Env.OS, exePath)
	Env.AppName = filepath.Base(exePath)

	if err := os.MkdirAll(Env.BasePath, 0o750); err != nil {
		log.Printf("Warning: failed to create app base path %s: %v", Env.BasePath, err)
	}

	if err := os.Setenv("PRIVATEDEPLOY_BASE_PATH", Env.BasePath); err != nil {
		log.Printf("Warning: failed to set PRIVATEDEPLOY_BASE_PATH: %v", err)
	}

	if slices.Contains(os.Args, "tasksch") {
		Env.FromTaskSch = true
	}

	app := NewApp()
	app.FileService = filesystem.NewService(Env.BasePath)

	// Initialize CloudManager with shared default provider registry
	registry := defaults.Registry()
	app.CloudManager = cloud.NewManager(context.Background(), registry)
	app.HealthMonitor = health.NewMonitor(5 * time.Minute)

	// Set Vultr as the default active provider
	if err := app.CloudManager.SetActiveProvider("vultr"); err != nil {
		log.Printf("Warning: Failed to set default provider: %v", err)
	}

	if Env.OS == "darwin" {
		createMacOSSymlink()
		createMacOSMenus(app)
	}

	extractEmbeddedFiles(fs)

	loadConfig()

	return app
}

func (a *App) IsStartup() bool {
	if Env.IsStartup {
		Env.IsStartup = false
		return true
	}
	return false
}

func (a *App) RestartApp() FlagResult {
	cmd := exec.Command(Env.ExecPath)
	SetCmdWindowHidden(cmd)

	if err := cmd.Start(); err != nil {
		return FlagResult{false, err.Error()}
	}

	a.ExitApp()

	return FlagResult{true, "Success"}
}

func (a *App) GetEnv() EnvResult {
	return EnvResult{
		AppName:      Env.AppName,
		AppVersion:   Env.AppVersion,
		BasePath:     Env.BasePath,
		OS:           Env.OS,
		ARCH:         Env.ARCH,
		Capabilities: buildPlatformCapabilities(Env.OS),
	}
}

func (a *App) GetInterfaces() FlagResult {
	log.Printf("GetInterfaces")

	interfaces, err := net.Interfaces()
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	var interfaceNames []string

	for _, inter := range interfaces {
		interfaceNames = append(interfaceNames, inter.Name)
	}

	return FlagResult{true, strings.Join(interfaceNames, "|")}
}

func (a *App) ShowMainWindow() {
	runtime.WindowShow(a.Ctx)
}

func createMacOSSymlink() {
	user, _ := user.Current()
	linkPath := Env.BasePath + "/data"
	appPath := "/Users/" + user.Username + "/Library/Application Support/" + Env.AppName
	os.MkdirAll(appPath, 0o750)
	os.Symlink(appPath, linkPath)
}

func resolveBasePath(osName, exePath string) string {
	exeDir := filepath.Dir(exePath)
	switch osName {
	case "linux":
		if !isLinuxSystemInstallPath(exeDir) {
			return exeDir
		}

		homeDir, err := os.UserHomeDir()
		if err != nil || homeDir == "" {
			return exeDir
		}

		return filepath.Join(homeDir, ".local", "share", "PrivateDeploy")
	case "windows":
		if !isWindowsSystemInstallPath(exeDir) {
			return exeDir
		}

		if localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); localAppData != "" {
			return filepath.Join(localAppData, "PrivateDeploy")
		}

		if userConfigDir, err := os.UserConfigDir(); err == nil && userConfigDir != "" {
			return filepath.Join(userConfigDir, "PrivateDeploy")
		}
	}

	return exeDir
}

func isLinuxSystemInstallPath(exeDir string) bool {
	candidates := []string{
		"/usr/bin",
		"/usr/local/bin",
		"/usr/lib",
		"/usr/local/lib",
		"/opt",
	}

	for _, candidate := range candidates {
		if exeDir == candidate || strings.HasPrefix(exeDir, candidate+"/") {
			return true
		}
	}

	return false
}

func isWindowsSystemInstallPath(exeDir string) bool {
	candidates := []string{
		strings.TrimSpace(os.Getenv("ProgramFiles")),
		strings.TrimSpace(os.Getenv("ProgramFiles(x86)")),
		strings.TrimSpace(os.Getenv("ProgramW6432")),
	}

	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		cleanCandidate := filepath.Clean(candidate)
		if exeDir == cleanCandidate || strings.HasPrefix(exeDir, cleanCandidate+string(filepath.Separator)) {
			return true
		}
	}

	return false
}

func buildPlatformCapabilities(osName string) PlatformCapabilities {
	capabilities := PlatformCapabilities{
		TraySupported:                  true,
		ShowMainWindowFromTray:         true,
		SystemProxySupported:           true,
		StartupLaunchSupported:         false,
		StartupDelaySupported:          false,
		AdminElevationSupported:        false,
		ConfigurableWebviewGpuPolicy:   false,
		KernelGrantPermissionSupported: true,
	}

	switch osName {
	case "windows":
		capabilities.ShowMainWindowFromTray = false
		capabilities.StartupLaunchSupported = true
		capabilities.StartupDelaySupported = true
		capabilities.AdminElevationSupported = true
		capabilities.KernelGrantPermissionSupported = false
	case "linux":
		capabilities.ConfigurableWebviewGpuPolicy = true
	case "darwin":
		// macOS keeps the standard tray and kernel grant flows.
	default:
		capabilities.TraySupported = false
		capabilities.ShowMainWindowFromTray = false
		capabilities.SystemProxySupported = false
		capabilities.KernelGrantPermissionSupported = false
	}

	return capabilities
}

func createMacOSMenus(app *App) {
	appMenu := app.AppMenu.AddSubmenu("App")
	appMenu.AddText("Show", keys.CmdOrCtrl("s"), func(_ *menu.CallbackData) {
		runtime.WindowShow(app.Ctx)
	})
	appMenu.AddText("Hide", keys.CmdOrCtrl("h"), func(_ *menu.CallbackData) {
		runtime.WindowHide(app.Ctx)
	})
	appMenu.AddSeparator()
	appMenu.AddText("Quit", keys.CmdOrCtrl("q"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.Ctx, "onExitApp")
	})

	// on macos platform, we should append EditMenu to enable Cmd+C,Cmd+V,Cmd+Z... shortcut
	app.AppMenu.Append(menu.EditMenu())
}

func extractEmbeddedFiles(fs embed.FS) {
	iconSrc := "frontend/dist/icons"
	iconDst := "data/.cache/icons"
	imgSrc := "frontend/dist/imgs"
	imgDst := "data/.cache/imgs"

	os.MkdirAll(GetPath(iconDst), 0o750)
	os.MkdirAll(GetPath(imgDst), 0o750)

	extractFiles(fs, iconSrc, iconDst)
	extractFiles(fs, imgSrc, imgDst)
}

func extractFiles(fs embed.FS, srcDir, dstDir string) {
	files, _ := fs.ReadDir(srcDir)
	for _, file := range files {
		fileName := file.Name()
		dstPath := GetPath(dstDir + "/" + fileName)
		if _, err := os.Stat(dstPath); os.IsNotExist(err) {
			log.Printf("InitResources [%s]: %s", dstDir, fileName)
			data, _ := fs.ReadFile(srcDir + "/" + fileName)
			if err := os.WriteFile(dstPath, data, os.ModePerm); err != nil {
				log.Printf("Error writing file %s: %v", dstPath, err)
			}
		}
	}
}

func loadConfig() {
	b, err := os.ReadFile(GetPath("data/user.yaml"))
	if err == nil {
		yaml.Unmarshal(b, &Config)
	}

	Config.WebviewGpuPolicy = resolveWebviewGpuPolicy(Env.OS, b, Config.WebviewGpuPolicy)

	if Config.Width == 0 {
		Config.Width = 800
	}

	if Config.Height == 0 {
		if Env.OS == "linux" {
			Config.Height = 510
		} else {
			Config.Height = 540
		}
	}

	Config.StartHidden = Env.FromTaskSch && Config.WindowStartState == int(options.Minimised)

	if !Env.FromTaskSch {
		Config.WindowStartState = int(options.Normal)
	}
}

func resolveWebviewGpuPolicy(osName string, rawConfig []byte, configuredPolicy int) int {
	if osName != "linux" {
		return configuredPolicy
	}

	if !hasUserConfigKey(rawConfig, "webviewGpuPolicy") {
		return webviewGpuPolicyNever
	}

	switch configuredPolicy {
	case webviewGpuPolicyAlways, webviewGpuPolicyNever:
		return configuredPolicy
	case webviewGpuPolicyOnDemand:
		log.Printf("Linux webviewGpuPolicy=OnDemand detected; forcing Never to avoid blank WebKit windows")
		return webviewGpuPolicyNever
	default:
		return webviewGpuPolicyNever
	}
}

func hasUserConfigKey(rawConfig []byte, key string) bool {
	if len(rawConfig) == 0 {
		return false
	}

	var settings map[string]any
	if err := yaml.Unmarshal(rawConfig, &settings); err != nil {
		return false
	}

	_, ok := settings[key]
	return ok
}
