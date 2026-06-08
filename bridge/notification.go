package bridge

import (
	"fmt"
	"os/exec"
	"runtime"
)

// Notify shells out to notify-send (Linux), terminal-notifier-equivalent
// PowerShell (Windows), or osascript (macOS) instead of using gen2brain/beeep.
// beeep transitively imports github.com/godbus/dbus/v5; that package init()
// races WebKitGTK's JSC initialization on Ubuntu noble and crashes the
// process at startup. By shelling out we keep godbus out of our address
// space entirely.
func (a *App) Notify(title string, message string, icon string, options NotifyOptions) FlagResult {
	fullPath := GetPath(icon)

	switch runtime.GOOS {
	case "linux":
		args := []string{"--app-name", options.AppName}
		if options.Beep {
			args = append(args, "--urgency=critical")
		}
		if fullPath != "" {
			args = append(args, "--icon", fullPath)
		}
		args = append(args, title, message)
		if err := exec.Command("notify-send", args...).Run(); err != nil {
			return FlagResult{false, err.Error()}
		}
	case "darwin":
		script := fmt.Sprintf(`display notification %q with title %q`, message, title)
		if err := exec.Command("osascript", "-e", script).Run(); err != nil {
			return FlagResult{false, err.Error()}
		}
	case "windows":
		// PowerShell BurntToast-free fallback via the legacy MessageBox API.
		ps := fmt.Sprintf(
			`Add-Type -AssemblyName System.Windows.Forms; `+
				`$n=New-Object System.Windows.Forms.NotifyIcon; `+
				`$n.Icon=[System.Drawing.SystemIcons]::Information; `+
				`$n.Visible=$true; `+
				`$n.ShowBalloonTip(5000, %q, %q, [System.Windows.Forms.ToolTipIcon]::Info)`,
			title, message,
		)
		if err := exec.Command("powershell", "-NoProfile", "-Command", ps).Run(); err != nil {
			return FlagResult{false, err.Error()}
		}
	default:
		return FlagResult{false, "unsupported platform"}
	}

	return FlagResult{true, "Success"}
}
