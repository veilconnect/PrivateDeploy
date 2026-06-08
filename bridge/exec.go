package bridge

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/process"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

func buildCmdEnv(customEnv map[string]string) []string {
	if len(customEnv) == 0 {
		return nil
	}

	env := os.Environ()
	for key, value := range customEnv {
		env = append(env, key+"="+value)
	}
	return env
}

func (a *App) Exec(path string, args []string, options ExecOptions) FlagResult {
	log.Printf("Exec: %s %s %v", path, args, options)

	exePath := GetPath(path)

	if _, err := os.Stat(exePath); os.IsNotExist(err) {
		exePath = path
	}

	cmd := exec.Command(exePath, args...)
	SetCmdWindowHidden(cmd)
	cmd.Env = buildCmdEnv(options.Env)

	out, err := cmd.CombinedOutput()
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	output := ""
	if options.Convert {
		output = ConvertByte2String(out)
	} else {
		output = string(out)
	}

	return FlagResult{true, output}
}

func (a *App) ExecBackground(path string, args []string, outEvent string, endEvent string, options ExecOptions) FlagResult {
	log.Printf("ExecBackground: %s %s %s %s %v", path, args, outEvent, endEvent, options)

	exePath := GetPath(path)

	if _, err := os.Stat(exePath); os.IsNotExist(err) {
		exePath = path
	}

	cmd := exec.Command(exePath, args...)
	SetCmdWindowHidden(cmd)
	cmd.Env = buildCmdEnv(options.Env)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		return FlagResult{false, err.Error()}
	}

	if outEvent != "" {
		scanAndEmit := func(reader io.Reader) {
			scanner := bufio.NewScanner(reader)
			stopOutput := false
			for scanner.Scan() {
				text := scanner.Text()

				if !stopOutput {
					runtime.EventsEmit(a.Ctx, outEvent, text)

					if options.StopOutputKeyword != "" && strings.Contains(text, options.StopOutputKeyword) {
						stopOutput = true
					}
				}
			}
		}

		go scanAndEmit(stdout)
	}

	if endEvent != "" {
		go func() {
			cmd.Wait()
			runtime.EventsEmit(a.Ctx, endEvent)
		}()
	}

	pid := cmd.Process.Pid

	return FlagResult{true, strconv.Itoa(pid)}
}

func (a *App) ProcessInfo(pid int32) FlagResult {
	log.Printf("ProcessInfo: %d", pid)

	proc, err := process.NewProcess(pid)
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	name, err := proc.Name()
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	return FlagResult{true, name}
}

func (a *App) KillProcess(pid int, timeout int) FlagResult {
	log.Printf("KillProcess: %d %d", pid, timeout)

	process, err := os.FindProcess(pid)
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	if err := SendExitSignal(process); err != nil {
		log.Printf("SendExitSignal Err: %s", err.Error())
	}

	if err := waitForProcessExitWithTimeout(process, timeout); err != nil {
		return FlagResult{false, err.Error()}
	}

	return FlagResult{true, "Success"}
}

// KillOrphanCores terminates any leftover sing-box processes whose executable
// lives under this app's BasePath. Returns a comma-separated list of PIDs that
// were killed (empty string if none).
//
// On Windows, bbolt's exclusive lock on cache.db survives an ungraceful app
// shutdown (installer overwrite, taskkill /F, power loss). The next launch
// then bounces five times on "initialize cache-file" errors before giving up
// because RemoveFile cannot delete a file with FILE_SHARE_NONE open. We clear
// the lock by killing the holder before spawning a new core.
func (a *App) KillOrphanCores() FlagResult {
	basePath := strings.TrimSpace(Env.BasePath)
	if basePath == "" {
		return FlagResult{false, "base path not initialized"}
	}
	basePath = filepath.Clean(basePath)

	procs, err := process.Processes()
	if err != nil {
		return FlagResult{false, err.Error()}
	}

	selfPid := int32(os.Getpid())
	killed := make([]string, 0, 2)

	for _, p := range procs {
		if p == nil || p.Pid == selfPid {
			continue
		}

		name, err := p.Name()
		if err != nil || !strings.HasPrefix(strings.ToLower(name), "sing-box") {
			continue
		}

		exe, err := p.Exe()
		// Skip if we can't confirm ownership — better to leave a process
		// alive than to kill an unrelated sing-box.
		if err != nil || exe == "" || !pathHasPrefix(exe, basePath) {
			continue
		}

		proc, err := os.FindProcess(int(p.Pid))
		if err != nil {
			log.Printf("KillOrphanCores: FindProcess(%d) failed: %v", p.Pid, err)
			continue
		}

		log.Printf("KillOrphanCores: terminating orphan sing-box pid=%d exe=%s", p.Pid, exe)
		if err := SendExitSignal(proc); err != nil {
			log.Printf("KillOrphanCores: SendExitSignal(%d): %v", p.Pid, err)
		}
		if err := waitForProcessExitWithTimeout(proc, 3); err != nil {
			log.Printf("KillOrphanCores: wait/kill(%d): %v", p.Pid, err)
		}
		killed = append(killed, strconv.Itoa(int(p.Pid)))
	}

	return FlagResult{true, strings.Join(killed, ",")}
}

// pathHasPrefix reports whether p lies under base, treating paths
// case-insensitively on Windows and normalizing mixed separators that
// gopsutil sometimes returns.
func pathHasPrefix(p, base string) bool {
	cp := filepath.Clean(p)
	cb := filepath.Clean(base)
	sep := "/"
	if Env.OS == "windows" {
		cp = strings.ReplaceAll(strings.ToLower(cp), `\`, "/")
		cb = strings.ReplaceAll(strings.ToLower(cb), `\`, "/")
	} else {
		sep = string(filepath.Separator)
	}
	if cp == cb {
		return true
	}
	if !strings.HasSuffix(cb, sep) {
		cb += sep
	}
	return strings.HasPrefix(cp, cb)
}

func waitForProcessExitWithTimeout(process *os.Process, timeoutSeconds int) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	defer cancel()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			if killErr := process.Kill(); killErr != nil {
				return fmt.Errorf("timed out after %d seconds waiting for process %d, and failed to kill it: %w", timeoutSeconds, process.Pid, killErr)
			}
			return nil

		case <-ticker.C:
			alive, err := IsProcessAlive(process)
			if err != nil {
				return fmt.Errorf("failed to check status of process %d: %w", process.Pid, err)
			}
			if !alive {
				return nil
			}
		}
	}
}
