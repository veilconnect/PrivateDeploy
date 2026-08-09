package bridge

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

const (
	frontendReadyFileEnv  = "PRIVATEDEPLOY_FRONTEND_READY_FILE"
	frontendReadyNonceEnv = "PRIVATEDEPLOY_FRONTEND_READY_NONCE"
	frontendReadyTitleEnv = "PRIVATEDEPLOY_FRONTEND_READY_TITLE"
)

// SignalFrontendReady is called by the Vue entrypoint only after Vue has
// mounted #app and a nextTick confirms that the root has rendered children.
//
// Normal launches do not set a challenge and therefore make this a no-op. The
// Linux installer supplies a unique state-file path and nonce, then verifies
// both fields and this process's PID. This is independent of X11/Wayland and
// cannot be satisfied by Wails' earlier OnDomReady callback alone.
func (a *App) SignalFrontendReady() error {
	statePath := strings.TrimSpace(os.Getenv(frontendReadyFileEnv))
	nonce := strings.TrimSpace(os.Getenv(frontendReadyNonceEnv))
	if statePath == "" && nonce == "" {
		return nil
	}
	if statePath == "" || nonce == "" {
		return fmt.Errorf("frontend-ready challenge is incomplete")
	}
	if !filepath.IsAbs(statePath) {
		return fmt.Errorf("%s must be an absolute path", frontendReadyFileEnv)
	}
	if !validFrontendReadyNonce(nonce) {
		return fmt.Errorf("%s is invalid", frontendReadyNonceEnv)
	}

	if err := writeFrontendReadyState(statePath, os.Getpid(), nonce, time.Now().UTC()); err != nil {
		return fmt.Errorf("write frontend-ready state: %w", err)
	}

	if title := strings.TrimSpace(os.Getenv(frontendReadyTitleEnv)); title != "" && a != nil && a.Ctx != nil {
		runtime.WindowSetTitle(a.Ctx, title)
	}
	log.Printf("[Startup] Vue frontend mounted (pid=%d)", os.Getpid())
	return nil
}

func validFrontendReadyNonce(nonce string) bool {
	if len(nonce) < 16 || len(nonce) > 128 {
		return false
	}
	for _, char := range nonce {
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			char == '-' || char == '_' || char == '.' {
			continue
		}
		return false
	}
	return true
}

func writeFrontendReadyState(path string, pid int, nonce string, readyAt time.Time) error {
	dir := filepath.Dir(path)
	info, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("state parent is not a directory: %s", dir)
	}

	temp, err := os.CreateTemp(dir, ".privatedeploy-frontend-ready.*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	committed := false
	defer func() {
		_ = temp.Close()
		if !committed {
			_ = os.Remove(tempPath)
		}
	}()

	if err := temp.Chmod(0o600); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(temp, "format=1\npid=%d\nnonce=%s\nready_at=%s\n", pid, nonce, readyAt.Format(time.RFC3339Nano)); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	committed = true
	return nil
}
