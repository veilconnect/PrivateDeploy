//go:build windows

package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/wailsapp/wails/v2/pkg/options"
)

const (
	wmCopyDataSingleInstanceData = 1542
	wmCopyData                   = 0x004A
)

var (
	user32           = syscall.NewLazyDLL("user32.dll")
	procFindWindowW  = user32.NewProc("FindWindowW")
	procSendMessageW = user32.NewProc("SendMessageW")
)

type copyDataStruct struct {
	dwData uintptr
	cbData uint32
	lpData uintptr
}

func handleInstallerQuitRequest(args []string) bool {
	uniqueID := installerSingleInstanceUniqueID()
	hwnd, err := findSingleInstanceWindow(uniqueID)
	if err != nil {
		log.Printf("[Startup] installer quit request: find single-instance window failed: %v", err)
		return true
	}
	if hwnd == 0 {
		log.Printf("[Startup] installer quit request: no running instance found")
		return true
	}
	if err := sendInstallerQuitToFirstInstance(hwnd, args); err != nil {
		log.Printf("[Startup] installer quit request: send failed: %v", err)
	}
	return true
}

func installerSingleInstanceUniqueID() string {
	exePath, err := os.Executable()
	if err == nil {
		if base := filepath.Base(exePath); base != "" {
			return base
		}
	}
	return "PrivateDeploy.exe"
}

func findSingleInstanceWindow(uniqueID string) (uintptr, error) {
	id := "wails-app-" + uniqueID
	className, err := syscall.UTF16PtrFromString(id + "-sic")
	if err != nil {
		return 0, err
	}
	windowName, err := syscall.UTF16PtrFromString(id + "-siw")
	if err != nil {
		return 0, err
	}
	hwnd, _, _ := procFindWindowW.Call(uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(windowName)))
	return hwnd, nil
}

func sendInstallerQuitToFirstInstance(hwnd uintptr, args []string) error {
	data := options.SecondInstanceData{Args: args}
	if wd, err := os.Getwd(); err == nil {
		data.WorkingDirectory = wd
	}
	serialized, err := json.Marshal(data)
	if err != nil {
		return err
	}
	message, err := syscall.UTF16FromString(string(serialized))
	if err != nil {
		return err
	}
	cds := copyDataStruct{
		dwData: wmCopyDataSingleInstanceData,
		cbData: uint32(len(message)*2 + 1),
		lpData: uintptr(unsafe.Pointer(&message[0])),
	}
	procSendMessageW.Call(hwnd, wmCopyData, 0, uintptr(unsafe.Pointer(&cds)))
	return nil
}
