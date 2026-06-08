package bridge

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

const (
	dialogSavePathEnv = "PRIVATEDEPLOY_DIALOG_SAVE_PATH"
	dialogOpenPathEnv = "PRIVATEDEPLOY_DIALOG_OPEN_PATH"
)

func defaultBackupDirectory() string {
	homeDir, err := os.UserHomeDir()
	if err == nil && homeDir != "" {
		return homeDir
	}

	if basePath := strings.TrimSpace(Env.BasePath); basePath != "" {
		return basePath
	}

	return "."
}

func (a *App) ExportCloudBackup(content string) (string, error) {
	targetPath := strings.TrimSpace(os.Getenv(dialogSavePathEnv))
	if targetPath == "" {
		if a.Ctx == nil {
			return "", fmt.Errorf("desktop dialog context unavailable")
		}

		path, err := runtime.SaveFileDialog(a.Ctx, runtime.SaveDialogOptions{
			Title:            "Export Cloud Backup",
			DefaultDirectory: defaultBackupDirectory(),
			DefaultFilename:  fmt.Sprintf("privatedeploy-backup-%d.json", time.Now().UnixMilli()),
			Filters: []runtime.FileFilter{
				{DisplayName: "JSON Files (*.json)", Pattern: "*.json"},
			},
			CanCreateDirectories: true,
			ShowHiddenFiles:      true,
		})
		if err != nil {
			return "", err
		}
		targetPath = strings.TrimSpace(path)
	}

	if targetPath == "" {
		return "", nil
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o750); err != nil {
		return "", err
	}
	if err := os.WriteFile(targetPath, []byte(content), 0o600); err != nil {
		return "", err
	}
	return targetPath, nil
}

func (a *App) ImportCloudBackup() (string, error) {
	sourcePath := strings.TrimSpace(os.Getenv(dialogOpenPathEnv))
	if sourcePath == "" {
		if a.Ctx == nil {
			return "", fmt.Errorf("desktop dialog context unavailable")
		}

		path, err := runtime.OpenFileDialog(a.Ctx, runtime.OpenDialogOptions{
			Title:            "Import Cloud Backup",
			DefaultDirectory: defaultBackupDirectory(),
			Filters: []runtime.FileFilter{
				{DisplayName: "JSON Files (*.json)", Pattern: "*.json"},
			},
			ShowHiddenFiles:      true,
			CanCreateDirectories: true,
		})
		if err != nil {
			return "", err
		}
		sourcePath = strings.TrimSpace(path)
	}

	if sourcePath == "" {
		return "", nil
	}

	data, err := os.ReadFile(sourcePath)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
