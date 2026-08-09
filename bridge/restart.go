package bridge

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/process"
)

// RestartParentPIDArg and RestartParentCreatedAtArg are private command-line
// arguments used only when one PrivateDeploy process hands a restart to its
// successor. Keeping the values in the bridge package prevents the launcher
// and the early main-process parser from drifting apart.
const (
	RestartParentPIDArg       = "--privatedeploy-internal-restart-parent-pid"
	RestartParentCreatedAtArg = "--privatedeploy-internal-restart-parent-created-ms"
)

// restartExecutable returns the outermost trusted launcher available. An
// AppImage must be restarted through the original AppImage file: Env.ExecPath
// points into a temporary FUSE mount that disappears when this process exits.
// Likewise, Linux package and local installs use a sibling wrapper around a
// *.bin payload to apply the WebKit/JSC compatibility environment.
func restartExecutable(osName, appImagePath, execPath string) (string, error) {
	if osName == "linux" {
		if candidate, ok := regularExecutable(appImagePath); ok {
			return candidate, nil
		}

		if strings.EqualFold(filepath.Ext(execPath), ".bin") {
			wrapperPath := strings.TrimSuffix(execPath, filepath.Ext(execPath))
			if candidate, ok := regularExecutable(wrapperPath); ok {
				return candidate, nil
			}
		}
	}

	if strings.TrimSpace(execPath) == "" {
		return "", fmt.Errorf("restart executable path is empty")
	}
	return execPath, nil
}

// regularExecutable accepts only an absolute, non-symlink regular executable.
// APPIMAGE is inherited from the environment, so it must never be trusted
// without all of these checks.
func regularExecutable(path string) (string, bool) {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return "", false
	}

	path = filepath.Clean(path)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", false
	}
	return path, true
}

func currentProcessCreatedAtMillis() (int64, error) {
	current, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		return 0, fmt.Errorf("inspect current process: %w", err)
	}
	createdAt, err := current.CreateTime()
	if err != nil {
		return 0, fmt.Errorf("read current process creation time: %w", err)
	}
	if createdAt <= 0 {
		return 0, fmt.Errorf("invalid current process creation time: %d", createdAt)
	}
	return createdAt, nil
}

func startRestartSuccessor() error {
	target, err := restartExecutable(Env.OS, os.Getenv("APPIMAGE"), Env.ExecPath)
	if err != nil {
		return err
	}

	createdAt, err := currentProcessCreatedAtMillis()
	if err != nil {
		return err
	}

	cmd := exec.Command(
		target,
		RestartParentPIDArg,
		strconv.Itoa(os.Getpid()),
		RestartParentCreatedAtArg,
		strconv.FormatInt(createdAt, 10),
	)
	SetCmdWindowHidden(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start restart successor: %w", err)
	}
	return nil
}
