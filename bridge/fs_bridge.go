package bridge

import (
	"fmt"
	"log"
	"strings"

	filesystem "privatedeploy/bridge/services/filesystem"
)

func (a *App) ensureFileService() *FlagResult {
	if a.FileService == nil {
		err := "file service not initialised"
		return &FlagResult{Flag: false, Data: err}
	}
	return nil
}

func toFilesystemOptions(options IOOptions) filesystem.Options {
	mode := filesystem.Mode(options.Mode)
	if mode == "" {
		mode = filesystem.ModeText
	}
	return filesystem.Options{Mode: mode}
}

func (a *App) WriteFile(path string, content string, options IOOptions) FlagResult {
	log.Printf("WriteFile [%s]: %s", options.Mode, path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.WriteFile(path, content, toFilesystemOptions(options)); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) ReadFile(path string, options IOOptions) FlagResult {
	log.Printf("ReadFile [%s]: %s", options.Mode, path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	data, err := a.FileService.ReadFile(path, toFilesystemOptions(options))
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: data}
}

func (a *App) MoveFile(source string, target string) FlagResult {
	log.Printf("MoveFile: %s -> %s", source, target)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.MoveFile(source, target); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) RemoveFile(path string) FlagResult {
	log.Printf("RemoveFile: %s", path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.RemoveFile(path); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) CopyFile(source string, target string) FlagResult {
	log.Printf("CopyFile: %s -> %s", source, target)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.CopyFile(source, target); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) MakeDir(path string) FlagResult {
	log.Printf("MakeDir: %s", path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.MakeDir(path); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) ReadDir(path string) FlagResult {
	log.Printf("ReadDir: %s", path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	entries, err := a.FileService.ReadDir(path)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if len(entries) == 0 {
		return FlagResult{Flag: true, Data: ""}
	}

	var builder strings.Builder
	for _, entry := range entries {
		builder.WriteString(fmt.Sprintf("%s,%d,%t|", entry.Name, entry.Size, entry.IsDir))
	}

	return FlagResult{Flag: true, Data: strings.TrimSuffix(builder.String(), "|")}
}

func (a *App) AbsolutePath(path string) FlagResult {
	log.Printf("AbsolutePath: %s", path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	absolutePath, err := a.FileService.AbsolutePath(path)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: absolutePath}
}

func (a *App) UnzipZIPFile(path string, output string) FlagResult {
	log.Printf("UnzipZIPFile: %s -> %s", path, output)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.UnzipZIPFile(path, output); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) UnzipTarGZFile(path string, output string) FlagResult {
	log.Printf("UnzipTarGZFile: %s -> %s", path, output)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.UnzipTarGZFile(path, output); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) UnzipGZFile(path string, output string) FlagResult {
	log.Printf("UnzipGZFile: %s -> %s", path, output)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	if err := a.FileService.UnzipGZFile(path, output); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) FileExists(path string) FlagResult {
	log.Printf("FileExists: %s", path)

	if res := a.ensureFileService(); res != nil {
		return *res
	}

	exists, err := a.FileService.FileExists(path)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: fmt.Sprintf("%t", exists)}
}
