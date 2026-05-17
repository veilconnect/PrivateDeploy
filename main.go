package main

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"io"
	"log"
	"net"
	"net/http"
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
	configureOptionalFileLogging()
	cleanStaleWebView2Locks()

	if err := validateLinuxDisplay(); err != nil {
		fmt.Fprintln(os.Stderr, formatStartupError(err))
		os.Exit(1)
	}

	linuxMinimalShell := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_LINUX_MINIMAL_SHELL") == "1"
	linuxStaticShell := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_LINUX_STATIC_SHELL") == "1"
	linuxBareShell := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_LINUX_BARE_SHELL") == "1"
	linuxSkipCreateApp := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_SKIP_CREATE_APP") == "1"
	openInspectorOnStartup := bridge.Env.OS == "linux" && os.Getenv("PRIVATEDEPLOY_OPEN_INSPECTOR_ON_STARTUP") == "1"
	skipRollingRelease := os.Getenv("PRIVATEDEPLOY_SKIP_ROLLING_RELEASE") == "1"

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

	app := func() *bridge.App {
		if !linuxSkipCreateApp {
			return bridge.CreateApp(assets)
		}

		configureDiagnosticShellEnv()
		log.Printf("[Startup] PRIVATEDEPLOY_SKIP_CREATE_APP=1: bypassing bridge.CreateApp() for Linux shell isolation")
		return bridge.NewApp()
	}()
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

	if linuxMinimalShell || linuxStaticShell || linuxBareShell {
		appMenu = nil
		windowWidth = 1280
		windowHeight = 840
		startHidden = false
		windowStartState = options.Normal
		singleInstanceLock = nil
	}

	var bindTargets []any
	if !linuxStaticShell && !linuxBareShell {
		bindTargets = []any{app}
	}

	backgroundColour := &options.RGBA{R: 255, G: 255, B: 255, A: 255}
	var linuxOptions *linux.Options
	if !linuxBareShell {
		linuxOptions = &linux.Options{
			Icon:                appIcon,
			WindowIsTranslucent: false,
			ProgramName:         bridge.Env.AppName,
			WebviewGpuPolicy:    linux.WebviewGpuPolicy(bridge.Config.WebviewGpuPolicy),
		}
	} else {
		backgroundColour = nil
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
		BackgroundColour: backgroundColour,
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
		Linux: linuxOptions,
		AssetServer: &assetserver.Options{
			Assets: frontendAssets,
			Middleware: func() func(http.Handler) http.Handler {
				if skipRollingRelease {
					return nil
				}
				return bridge.RollingRelease
			}(),
		},
		SingleInstanceLock: singleInstanceLock,
		OnStartup: func(ctx context.Context) {
			app.Ctx = ctx
			if linuxStaticShell || linuxBareShell {
				return
			}
			if !linuxMinimalShell {
				trayStart()
			}
			app.SetupSSHEventEmitter()
		},
		OnDomReady: func(ctx context.Context) {
			if signalTitle := strings.TrimSpace(os.Getenv("PRIVATEDEPLOY_DEBUG_SIGNAL_TITLE")); signalTitle != "" {
				go func() {
					time.Sleep(1200 * time.Millisecond)
					runtime.WindowSetTitle(ctx, signalTitle)
					runtime.WindowExecJS(ctx, fmt.Sprintf(`(function () {
  document.title = %q;
  if (document.body) {
    document.body.setAttribute('data-pd-smoke', 'dom-ready');
  }
})();`, signalTitle))
				}()
			}

			if os.Getenv("PRIVATEDEPLOY_DEBUG_DUMP_DOM") == "1" {
				go func() {
					time.Sleep(1800 * time.Millisecond)
					runtime.WindowExecJS(ctx, `(function () {
  const app = document.getElementById('app');
  const fatal = document.getElementById('startup-fatal');
  const route = window.location ? window.location.hash || window.location.href : '';
  const payload = {
    route,
    bodyText: (document.body && document.body.innerText || '').slice(0, 400),
    appText: (app && app.innerText || '').slice(0, 400),
    fatalText: (fatal && fatal.innerText || '').slice(0, 400),
    bodyBg: document.body ? getComputedStyle(document.body).backgroundColor : '',
    appBg: app ? getComputedStyle(app).backgroundColor : '',
    bodyChildren: document.body ? document.body.childElementCount : -1,
    appChildren: app ? app.childElementCount : -1,
    readyState: document.readyState
  };
  console.info('[PrivateDeploy] [DOMDump]', JSON.stringify(payload));
})();`)
				}()
			}

			if os.Getenv("PRIVATEDEPLOY_DEBUG_FORCE_PAINT") == "1" {
				go func() {
					time.Sleep(3200 * time.Millisecond)
					runtime.WindowExecJS(ctx, `(function () {
  document.documentElement.style.background = 'rgb(0, 255, 0)';
  document.body.style.background = 'rgb(0, 255, 0)';
  document.body.style.color = 'rgb(0, 0, 0)';
  document.body.innerHTML = '<pre id="pd-force-paint" style="padding:24px;font:24px monospace;background:rgb(0,255,0);color:black">PD FORCE PAINT</pre>';
  console.info('[PrivateDeploy] [ForcePaint] injected');
})();`)
				}()
			}

			if bridge.Env.OS != "linux" || linuxMinimalShell || linuxStaticShell || linuxBareShell {
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
			if bridge.Env.OS == "windows" || bridge.Env.OS == "linux" {
				runtime.WindowHide(ctx)
				return true
			}
			runtime.EventsEmit(ctx, "onBeforeExitApp")
			return true
		},
		Bind:     bindTargets,
		LogLevel: logger.INFO,
		Debug: options.Debug{
			OpenInspectorOnStartup: openInspectorOnStartup,
		},
	})

	if err != nil {
		fmt.Fprintln(os.Stderr, formatStartupError(err))
		os.Exit(1)
	}
}

// webView2LockNames are the Chromium/WebView2 lock files that can persist
// after an unclean shutdown and prevent the next CreateCoreWebView2Controller
// call from succeeding.
var webView2LockNames = map[string]struct{}{
	"SingletonLock":   {},
	"SingletonCookie": {},
	"SingletonSocket": {},
	"lockfile":        {},
	"LOCK":            {},
}

// cleanStaleWebView2Locks removes Chromium/WebView2 lock files left in the
// user-data folder by a previously-crashed instance. The cleanup is best-effort
// and Windows-only: if a live process still holds the file open, os.Remove
// fails and we leave the file alone.
//
// Background: a hard crash of PrivateDeploy could leave SingletonLock and
// friends in WebView2's user-data folder. The next start would log a stack
// trace from go-webview2/Chromium.Embed and the process would exit before the
// main window appeared. Cleaning these on startup turns that crash-loop into
// a self-healing one.
func cleanStaleWebView2Locks() {
	if bridge.Env.OS != "windows" {
		return
	}
	for _, folder := range webView2UserDataCandidates() {
		cleanWebView2LocksIn(folder)
	}
}

// webView2UserDataCandidates returns the paths where wails / go-webview2 might
// have placed the user-data folder. We do not know which one was used (it
// depends on Wails version, working directory at launch, and whether the
// WEBVIEW2_USER_DATA_FOLDER env var is set), so we sweep all of them.
func webView2UserDataCandidates() []string {
	var paths []string
	if explicit := strings.TrimSpace(os.Getenv("WEBVIEW2_USER_DATA_FOLDER")); explicit != "" {
		paths = append(paths, explicit)
	}

	exePath, err := os.Executable()
	if err != nil {
		return paths
	}
	exeDir := filepath.Dir(exePath)
	exeBase := filepath.Base(exePath)
	if ext := filepath.Ext(exeBase); strings.EqualFold(ext, ".exe") {
		exeBase = strings.TrimSuffix(exeBase, ext)
	}
	if exeBase == "" {
		return paths
	}
	wv2Name := exeBase + ".WebView2"

	paths = append(paths, filepath.Join(exeDir, wv2Name))
	if cwd, err := os.Getwd(); err == nil && cwd != exeDir {
		paths = append(paths, filepath.Join(cwd, wv2Name))
	}
	if local := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); local != "" {
		paths = append(paths, filepath.Join(local, exeBase, wv2Name))
	}
	return paths
}

// cleanWebView2LocksIn removes known Chromium/WebView2 lock-named files under
// folder, recursively. Returns the number of files actually removed. A live
// process still holding a lock will block os.Remove on Windows; that is the
// natural safety mechanism.
func cleanWebView2LocksIn(folder string) int {
	if folder == "" {
		return 0
	}
	info, err := os.Stat(folder)
	if err != nil || !info.IsDir() {
		return 0
	}
	cleaned := 0
	_ = filepath.WalkDir(folder, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() {
			return nil
		}
		if _, ok := webView2LockNames[d.Name()]; !ok {
			return nil
		}
		if removeErr := os.Remove(path); removeErr == nil {
			cleaned++
			log.Printf("[Startup] Cleaned stale WebView2 lock: %s", path)
		}
		return nil
	})
	return cleaned
}

func configureOptionalFileLogging() {
	logPath := strings.TrimSpace(os.Getenv("PRIVATEDEPLOY_LOG_FILE"))
	if logPath == "" {
		return
	}

	if err := os.MkdirAll(filepath.Dir(logPath), 0o750); err != nil {
		fmt.Fprintf(os.Stderr, "failed to create log directory %s: %v\n", logPath, err)
		return
	}

	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to open log file %s: %v\n", logPath, err)
		return
	}

	log.SetOutput(&isolatedFanoutWriter{writers: []io.Writer{os.Stderr, file}})
	log.Printf("[Startup] File logging enabled: %s", logPath)
}

// isolatedFanoutWriter writes each payload to every backing writer
// independently. Unlike io.MultiWriter it does not abort the fan-out when one
// writer fails, so a missing console stderr (e.g., a Windows scheduled task
// without an attached console) cannot silently suppress writes to the log
// file. Errors are swallowed because logging is best-effort.
type isolatedFanoutWriter struct {
	writers []io.Writer
}

func (f *isolatedFanoutWriter) Write(p []byte) (int, error) {
	for _, w := range f.writers {
		_, _ = w.Write(p)
	}
	return len(p), nil
}

func configureDiagnosticShellEnv() {
	exePath, err := os.Executable()
	if err == nil {
		bridge.Env.ExecPath = exePath
		if bridge.Env.AppName == "" {
			bridge.Env.AppName = filepath.Base(exePath)
		}
		if bridge.Env.BasePath == "" {
			bridge.Env.BasePath = filepath.Dir(exePath)
		}
		return
	}

	if bridge.Env.AppName == "" {
		bridge.Env.AppName = "PrivateDeploy"
	}
	if bridge.Env.BasePath == "" {
		if cwd, cwdErr := os.Getwd(); cwdErr == nil && cwd != "" {
			bridge.Env.BasePath = cwd
		}
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

	xdpyinfoOutput := ""
	if _, err := exec.LookPath("xdpyinfo"); err == nil {
		cmd := exec.Command("xdpyinfo")
		cmd.Env = append(os.Environ(), "DISPLAY="+display)
		if xAuthority != "" {
			cmd.Env = append(cmd.Env, "XAUTHORITY="+xAuthority)
		}
		output, err := cmd.CombinedOutput()
		if err != nil {
			detail := strings.TrimSpace(string(output))
			if detail == "" {
				detail = err.Error()
			}
			if len(detail) > 160 {
				detail = detail[:160] + "..."
			}
			return fmt.Errorf("X11 display %q is not accessible: %s", display, detail)
		}
		xdpyinfoOutput = string(output)
	}

	if os.Getenv("PRIVATEDEPLOY_ALLOW_UNSUPPORTED_REMOTE_DISPLAY") == "1" {
		return nil
	}

	xrandrOutput := ""
	if _, err := exec.LookPath("xrandr"); err == nil {
		cmd := exec.Command("xrandr", "--verbose")
		cmd.Env = append(os.Environ(), "DISPLAY="+display)
		if xAuthority != "" {
			cmd.Env = append(cmd.Env, "XAUTHORITY="+xAuthority)
		}
		output, err := cmd.CombinedOutput()
		if err == nil {
			xrandrOutput = string(output)
		}
	}

	if reason, unsupported := detectUnsupportedLinuxRemoteDisplay(
		display,
		waylandDisplay,
		os.Getenv("SSH_CONNECTION"),
		xdpyinfoOutput,
		xrandrOutput,
	); unsupported {
		return fmt.Errorf("%s Set PRIVATEDEPLOY_ALLOW_UNSUPPORTED_REMOTE_DISPLAY=1 to try anyway.", reason)
	}

	return nil
}

func detectUnsupportedLinuxRemoteDisplay(display, waylandDisplay, sshConnection, xdpyinfoOutput, xrandrOutput string) (string, bool) {
	if waylandDisplay != "" || display == "" {
		return "", false
	}

	normalizedDisplay := strings.TrimSpace(display)
	if sshConnection != "" && (strings.HasPrefix(normalizedDisplay, "localhost:") || strings.HasPrefix(normalizedDisplay, "127.0.0.1:")) {
		return "Remote Linux X11 forwarding is not supported by this build because WebKitGTK renders blank windows in forwarded sessions.", true
	}

	if strings.Contains(xdpyinfoOutput, "VNC-EXTENSION") || strings.Contains(xrandrOutput, "VNC-") {
		return "Remote Linux VNC desktops are not supported by this build because WebKitGTK renders blank windows in VNC sessions.", true
	}

	return "", false
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
	if strings.Contains(message, "failed to init GTK") || strings.Contains(message, "X11 display") || strings.Contains(message, "X11 socket") || strings.Contains(message, "desktop runtime panic") || strings.Contains(message, "no GUI display detected") || strings.Contains(message, "WAYLAND_DISPLAY") || strings.Contains(message, "renders blank windows") {
		return fmt.Sprintf(
			"Error: %s\nLinux GUI startup check failed. Current DISPLAY=%q WAYLAND_DISPLAY=%q.\nPlease launch from a desktop terminal with a valid display session.",
			err.Error(),
			os.Getenv("DISPLAY"),
			os.Getenv("WAYLAND_DISPLAY"),
		)
	}

	return "Error: " + err.Error()
}
