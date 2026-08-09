package bridge

import (
	"context"
	"crypto/sha256"
	"embed"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"time"

	sysruntime "runtime"

	"privatedeploy/bridge/cdn"
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
	basePathEnv              = "PRIVATEDEPLOY_BASE_PATH"
	appNameEnv               = "PRIVATEDEPLOY_APP_NAME"
	linuxDataRootChoiceFile  = "data-root"
)

// AppVersion is the build-time version of the binary. Default "dev" makes
// it obvious when an unbranded local build is running. Override at link
// time with:
//
//	go build -ldflags "-X privatedeploy/bridge.AppVersion=v2.0.0+12" ./api
//	go build -ldflags "-X privatedeploy/bridge.AppVersion=v2.0.0+12" .
//
// Both /api/v1/version and /api/v1/health expose this value at runtime so
// the deployed binary can always be queried for its build identity.
var AppVersion = "dev"

var Env = &EnvResult{
	IsStartup:    true,
	FromTaskSch:  false,
	ExecPath:     "",
	AppName:      "",
	AppVersion:   AppVersion,
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
	Env.BasePath = configuredBasePath(resolveBasePath(Env.OS, exePath))
	Env.AppName = configuredAppName(filepath.Base(exePath))

	if err := os.MkdirAll(Env.BasePath, 0o750); err != nil {
		log.Printf("Warning: failed to create app base path %s: %v", Env.BasePath, err)
	}

	if err := os.Setenv(basePathEnv, Env.BasePath); err != nil {
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
	app.CdnManager = cdn.NewManager(Env.BasePath)

	// Restore the provider selected for this exact data root. Falling back on
	// every restart would load a different credential/node slot and look like
	// user data had disappeared.
	if err := app.restoreActiveCloudProvider("vultr"); err != nil {
		log.Printf("Warning: failed to restore active provider: %v", err)
	}

	if Env.OS == "darwin" {
		createMacOSSymlink()
		createMacOSMenus(app)
	}

	extractEmbeddedFiles(fs)
	seedRuntimeData()

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
	if err := startRestartSuccessor(); err != nil {
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

// configuredBasePath keeps portable installs stable when a launcher executes a
// versioned or compatibility binary beside it. Only an absolute path is
// accepted because BasePath owns mutable configuration and credential files.
func configuredBasePath(fallback string) string {
	override := strings.TrimSpace(os.Getenv(basePathEnv))
	if override == "" {
		return fallback
	}
	if !filepath.IsAbs(override) {
		log.Printf("Warning: ignoring non-absolute %s value %q", basePathEnv, override)
		return fallback
	}
	return filepath.Clean(override)
}

// configuredAppName lets the Linux launcher preserve the historical
// PrivateDeploy identity even though the real executable is PrivateDeploy.bin.
func configuredAppName(fallback string) string {
	override := strings.TrimSpace(os.Getenv(appNameEnv))
	if override == "" {
		return fallback
	}
	if override == "." || override == ".." || strings.ContainsAny(override, `/\`) {
		log.Printf("Warning: ignoring invalid %s value %q", appNameEnv, override)
		return fallback
	}
	return override
}

func resolveBasePath(osName, exePath string) string {
	exeDir := filepath.Dir(exePath)
	switch osName {
	case "linux":
		// AppImage mounts a read-only squashfs at /tmp/.mount_xxx/. Always
		// redirect to the user data dir when running from one, or any other
		// system install path.
		if !isLinuxSystemInstallPath(exeDir) && !isAppImageRuntime(exeDir) {
			return exeDir
		}

		homeDir, err := os.UserHomeDir()
		if err != nil || homeDir == "" {
			return exeDir
		}

		return chooseLinuxPersistentBasePath(homeDir)
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

// chooseLinuxPersistentBasePath keeps AppImage, package and historical local
// installs on one data root. Older local releases stored mutable data beside
// ~/.local/bin/PrivateDeploy, while system/AppImage releases used XDG data.
// Once selected, the root is recorded so switching packages cannot make saved
// API credentials or nodes appear to disappear. Divergent roots are never
// copied over one another or silently merged.
func chooseLinuxPersistentBasePath(homeDir string) string {
	homeDir = filepath.Clean(homeDir)
	canonical := filepath.Join(homeDir, ".local", "share", "PrivateDeploy")
	legacy := filepath.Join(homeDir, ".local", "bin")
	choicePath := filepath.Join(homeDir, ".config", "PrivateDeploy", linuxDataRootChoiceFile)

	choiceInfo, choiceInfoErr := os.Lstat(choicePath)
	if choiceInfoErr == nil && choiceInfo.Mode().IsRegular() {
		raw, err := os.ReadFile(choicePath)
		if err != nil {
			log.Printf("Warning: unable to read Linux data-root choice: %v", err)
		} else {
			choice := filepath.Clean(strings.TrimSpace(string(raw)))
			if choice == canonical || choice == legacy {
				return choice
			}
			log.Printf("Warning: ignoring invalid Linux data-root choice %q", choice)
		}
	}

	selected := canonical
	canonicalTime, canonicalScore := linuxDataRootActivity(canonical)
	legacyTime, legacyScore := linuxDataRootActivity(legacy)
	if legacyScore > canonicalScore || (legacyScore > 0 && legacyScore == canonicalScore && legacyTime.After(canonicalTime)) {
		selected = legacy
	}
	if err := persistLinuxDataRootChoice(choicePath, selected); err != nil {
		log.Printf("Warning: unable to persist Linux data-root choice: %v", err)
	}
	return selected
}

func linuxDataRootActivity(root string) (time.Time, int) {
	var newest time.Time
	score := 0
	dataDir := filepath.Join(root, "data")
	_ = filepath.WalkDir(dataDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		info, infoErr := entry.Info()
		if infoErr != nil || !info.Mode().IsRegular() {
			return nil
		}
		weight := linuxDurableStateWeight(dataDir, path)
		if weight == 0 {
			return nil
		}
		score += weight
		// The launcher uses GNU stat's seconds-since-epoch value; use the same
		// precision here so the backend and launcher cannot disagree.
		modified := time.Unix(info.ModTime().Unix(), 0)
		if modified.After(newest) {
			newest = modified
		}
		return nil
	})
	return newest, score
}

// linuxDurableStateWeight deliberately recognises only user-owned state. A
// freshly installed core, extracted GUI assets, caches and generated sing-box
// runtime files must never make an otherwise empty root look newer than the
// root containing saved cloud credentials and nodes.
//
// Weights make node/provider state outrank a newly generated default settings
// file. Within roots containing the same kinds of state, the newest durable
// file is the tie-breaker. Unknown paths are ignored so future build artifacts
// cannot silently change an already established migration decision.
func linuxDurableStateWeight(dataDir, path string) int {
	rel, err := filepath.Rel(dataDir, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return 0
	}
	rel = filepath.ToSlash(rel)

	switch rel {
	case "user.yaml", "profiles.yaml", "subscribes.yaml",
		"rulesets.yaml", "plugins.yaml", "scheduledtasks.yaml":
		return 16
	case "privatedeploy.db":
		return 8
	case "cloud/active-provider":
		return 32
	case "cdn/config.json", "cdn/deployments.json":
		return 16
	}

	if strings.HasPrefix(rel, "cloud/") {
		name := strings.TrimPrefix(rel, "cloud/")
		// Provider records live directly below data/cloud. In-flight operation
		// locks/journals and derived health/history files are runtime state and
		// intentionally do not participate in choosing a root.
		if strings.Contains(name, "/") {
			return 0
		}
		switch {
		case strings.HasSuffix(name, "-nodes.json"):
			return 64
		case strings.HasSuffix(name, "-config.json"):
			return 32
		case name == "ssh-known-hosts.json":
			return 16
		}
		return 0
	}

	if strings.HasPrefix(rel, "subscribes/") {
		name := strings.TrimPrefix(rel, "subscribes/")
		if strings.Contains(name, "/") {
			return 0
		}
		ext := strings.ToLower(filepath.Ext(name))
		if ext == ".json" || ext == ".yaml" || ext == ".yml" {
			return 8
		}
	}
	return 0
}

func persistLinuxDataRootChoice(path, root string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".data-root.*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.WriteString(root + "\n"); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

// isAppImageRuntime returns true when the binary is running from an AppImage
// FUSE mount (squashfs at /tmp/.mount_<hash>/...) or extracted AppDir
// (APPDIR env var set by the AppImage runtime). Both surfaces are read-only
// for the AppImage case, so we redirect BasePath to the user data dir.
func isAppImageRuntime(exeDir string) bool {
	if strings.TrimSpace(os.Getenv("APPDIR")) != "" {
		return true
	}
	return strings.HasPrefix(exeDir, "/tmp/.mount_")
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

	normalize := func(path string) string {
		path = strings.ToLower(strings.TrimSpace(filepath.Clean(path)))
		path = strings.ReplaceAll(path, `\`, `/`)
		// Windows installers and scheduled launches may surface 8.3 short paths.
		// Normalize the common Program Files prefixes so system installs still
		// resolve to LOCALAPPDATA instead of writing into the install directory.
		path = strings.ReplaceAll(path, `/progra~1`, `/program files`)
		path = strings.ReplaceAll(path, `/progra~2`, `/program files (x86)`)
		return path
	}

	cleanExeDir := normalize(exeDir)
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		cleanCandidate := normalize(candidate)
		if cleanExeDir == cleanCandidate || strings.HasPrefix(cleanExeDir, cleanCandidate+"/") {
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
		// Linux is deliberately pinned to software rendering. Exposing a GPU
		// selector would let the frontend persist a value the backend must reject.
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
		data, _ := fs.ReadFile(srcDir + "/" + fileName)
		existing, err := os.ReadFile(dstPath)
		if err == nil && string(existing) == string(data) {
			continue
		}

		if os.IsNotExist(err) {
			log.Printf("InitResources [%s]: %s", dstDir, fileName)
		} else {
			log.Printf("RefreshResources [%s]: %s", dstDir, fileName)
		}

		if err := os.WriteFile(dstPath, data, os.ModePerm); err != nil {
			log.Printf("Error writing file %s: %v", dstPath, err)
		}
	}
}

// seedRuntimeData copies bundled runtime data (e.g. sing-box binary) from the
// installation directory to BasePath when BasePath differs from the exe directory
// (i.e. on Windows system installs where BasePath is %LOCALAPPDATA%\PrivateDeploy).
// Existing files are refreshed when the bundled copy changes so upgrades do not
// leave behind a stale runtime.
func seedRuntimeData() {
	exeDir := filepath.Dir(Env.ExecPath)
	basePath := Env.BasePath

	// Only needed when BasePath is redirected away from the exe directory.
	if filepath.Clean(exeDir) == filepath.Clean(basePath) {
		return
	}

	// Files to seed from install dir → BasePath (relative paths).
	seeds := []string{
		filepath.Join("data", "sing-box", "sing-box"),
	}
	if sysruntime.GOOS == "windows" {
		seeds = []string{
			filepath.Join("data", "sing-box", "sing-box.exe"),
		}
	}

	for _, rel := range seeds {
		src, srcInfo, err := findRuntimeSeedSource(runtimeSeedCandidates(exeDir, rel, sysruntime.GOOS))
		if err != nil {
			log.Printf("seedRuntimeData: reject bundled %s: %v", rel, err)
			continue
		}
		if src == "" {
			continue
		}
		dst := filepath.Join(basePath, rel)

		shouldCopy, err := shouldRefreshSeededFile(src, dst, srcInfo)
		if err != nil {
			log.Printf("seedRuntimeData: compare %s → %s: %v", src, dst, err)
			continue
		}
		if !shouldCopy {
			continue
		}

		if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
			log.Printf("seedRuntimeData: mkdir %s: %v", filepath.Dir(dst), err)
			continue
		}

		if err := copyFileAtomic(src, dst, srcInfo.Mode()); err != nil {
			log.Printf("seedRuntimeData: copy %s → %s: %v", src, dst, err)
		} else {
			log.Printf("seedRuntimeData: seeded %s", rel)
		}
	}
}

// runtimeSeedCandidates preserves the historical portable/raw layout first.
// AppImages execute the Wails binary from usr/bin but keep mutable runtime data
// under usr/lib/privatedeploy, so Linux needs a second packaging-layout
// candidate when BasePath is redirected to the user's canonical data root.
func runtimeSeedCandidates(exeDir, rel, osName string) []string {
	candidates := []string{filepath.Join(exeDir, rel)}
	if osName == "linux" {
		candidates = append(candidates, filepath.Clean(filepath.Join(
			exeDir,
			"..",
			"lib",
			"privatedeploy",
			rel,
		)))
	}
	return candidates
}

// findRuntimeSeedSource accepts only a real executable regular file. Refusing
// symlinks and non-executable payloads prevents an install-layout mistake (or a
// replaced AppDir entry) from being copied into the user's trusted runtime.
func findRuntimeSeedSource(candidates []string) (string, os.FileInfo, error) {
	for _, candidate := range candidates {
		info, err := os.Lstat(candidate)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", nil, fmt.Errorf("inspect %s: %w", candidate, err)
		}
		if !info.Mode().IsRegular() {
			return "", nil, fmt.Errorf("%s is not a regular file", candidate)
		}
		if sysruntime.GOOS != "windows" && info.Mode().Perm()&0o111 == 0 {
			return "", nil, fmt.Errorf("%s is not executable", candidate)
		}
		return candidate, info, nil
	}
	return "", nil, nil
}

func shouldRefreshSeededFile(src, dst string, srcInfo os.FileInfo) (bool, error) {
	dstInfo, err := os.Lstat(dst)
	if err != nil {
		if os.IsNotExist(err) {
			return true, nil
		}
		return false, err
	}

	if !dstInfo.Mode().IsRegular() {
		return false, fmt.Errorf("destination is not a regular file: %s", dst)
	}

	if dstInfo.Size() != srcInfo.Size() {
		return true, nil
	}
	if sysruntime.GOOS != "windows" && srcInfo.Mode().Perm()&0o111 != 0 && dstInfo.Mode().Perm()&0o111 == 0 {
		return true, nil
	}

	equal, err := filesHaveSameHash(src, dst)
	if err != nil {
		return false, err
	}
	return !equal, nil
}

// copyFileAtomic stages a complete, fsynced runtime beside the destination and
// publishes it with one rename. Any validation/copy failure leaves the previous
// core intact. Both source and destination are lstat'ed so symlinks and
// directories are rejected instead of followed or overwritten.
func copyFileAtomic(src, dst string, perm os.FileMode) error {
	srcInfo, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if !srcInfo.Mode().IsRegular() {
		return fmt.Errorf("source is not a regular file: %s", src)
	}
	if sysruntime.GOOS != "windows" && srcInfo.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("source is not executable: %s", src)
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	openedInfo, err := in.Stat()
	if err != nil {
		return err
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(srcInfo, openedInfo) {
		return fmt.Errorf("source changed while opening: %s", src)
	}

	if dstInfo, dstErr := os.Lstat(dst); dstErr == nil {
		if !dstInfo.Mode().IsRegular() {
			return fmt.Errorf("destination is not a regular file: %s", dst)
		}
	} else if !errors.Is(dstErr, os.ErrNotExist) {
		return dstErr
	}

	dstDir := filepath.Dir(dst)
	out, err := os.CreateTemp(dstDir, "."+filepath.Base(dst)+".seed.*")
	if err != nil {
		return err
	}
	tempPath := out.Name()
	committed := false
	defer func() {
		_ = out.Close()
		if !committed {
			_ = os.Remove(tempPath)
		}
	}()

	if err := out.Chmod(perm.Perm()); err != nil {
		return err
	}

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}

	// Re-check immediately before publication. A directory or symlink must never
	// be replaced even if it appeared after the first destination inspection.
	if dstInfo, dstErr := os.Lstat(dst); dstErr == nil {
		if !dstInfo.Mode().IsRegular() {
			return fmt.Errorf("destination changed to a non-regular file: %s", dst)
		}
	} else if !errors.Is(dstErr, os.ErrNotExist) {
		return dstErr
	}

	if err := os.Rename(tempPath, dst); err != nil {
		return err
	}
	committed = true

	// The payload itself is already durable and atomically visible. Sync the
	// containing directory on platforms that support it; a failure here cannot
	// safely undo the committed rename, so it remains a best-effort durability
	// enhancement rather than reporting a false rollback.
	if dir, openErr := os.Open(dstDir); openErr == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}

func filesHaveSameHash(src, dst string) (bool, error) {
	srcHash, err := hashFile(src)
	if err != nil {
		return false, err
	}

	dstHash, err := hashFile(dst)
	if err != nil {
		return false, err
	}

	return srcHash == dstHash, nil
}

func hashFile(path string) ([sha256.Size]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	defer file.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return [sha256.Size]byte{}, err
	}

	var digest [sha256.Size]byte
	copy(digest[:], hasher.Sum(nil))
	return digest, nil
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

	// A persisted Always/OnDemand value can make the Jammy WebKit AppImage load
	// its bundled GTK stack together with the host's NVIDIA/Mesa EGL stack. The
	// DOM still runs, but the composited WebView surface remains entirely white.
	// Linux therefore has one supported policy: software rendering. This also
	// migrates older user.yaml files that explicitly saved Always (zero).
	if hasUserConfigKey(rawConfig, "webviewGpuPolicy") && configuredPolicy != webviewGpuPolicyNever {
		log.Printf("Linux webviewGpuPolicy=%d detected; forcing Never to avoid blank WebKit windows", configuredPolicy)
	}
	return webviewGpuPolicyNever
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
