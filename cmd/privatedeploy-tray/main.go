// privatedeploy-tray is a small sidecar binary that owns the system tray.
// The main Wails binary spawns it and talks via JSON-lines on stdin/stdout.
//
// Why a sidecar: github.com/energye/systray pulls in github.com/godbus/dbus/v5,
// whose package init() perturbs JSC's GC signal install on noble — the main
// binary segfaults at gtk_main with addr=0x48 the moment WebKit initializes.
// Isolating tray + dbus into a separate process keeps godbus's runtime side
// effects out of the WebKit address space.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"sync"

	"github.com/energye/systray"

	"privatedeploy/bridge/trayipc"
)

var (
	mu    sync.Mutex
	items = make(map[string]*systray.MenuItem)
)

func emit(ev trayipc.Event) {
	b, _ := json.Marshal(ev)
	os.Stdout.Write(append(b, '\n'))
}

func handleCmd(c trayipc.Cmd) {
	mu.Lock()
	defer mu.Unlock()
	switch c.Op {
	case "init":
		if c.IconB64 != "" {
			if icon, err := base64.StdEncoding.DecodeString(c.IconB64); err == nil {
				systray.SetIcon(icon)
			}
		}
		if c.Tooltip != "" {
			systray.SetTooltip(c.Tooltip)
		}
	case "set_icon":
		if c.IconB64 != "" {
			if icon, err := base64.StdEncoding.DecodeString(c.IconB64); err == nil {
				systray.SetIcon(icon)
			}
		}
	case "set_title":
		systray.SetTitle(c.Value)
	case "set_tooltip":
		systray.SetTooltip(c.Value)
	case "reset_menu":
		systray.ResetMenu()
		items = make(map[string]*systray.MenuItem)
	case "add_item":
		m := systray.AddMenuItem(c.Title, c.Tooltip)
		items[c.ID] = m
		id := c.ID
		m.Click(func() { emit(trayipc.Event{Op: "click", ID: id}) })
		if c.Checked {
			m.Check()
		}
	case "add_sub_item":
		parent, ok := items[c.ParentID]
		if !ok {
			return
		}
		m := parent.AddSubMenuItem(c.Title, c.Tooltip)
		items[c.ID] = m
		id := c.ID
		m.Click(func() { emit(trayipc.Event{Op: "click", ID: id}) })
		if c.Checked {
			m.Check()
		}
	case "add_separator":
		systray.AddSeparator()
	case "check":
		if m, ok := items[c.ID]; ok {
			m.Check()
		}
	case "uncheck":
		if m, ok := items[c.ID]; ok {
			m.Uncheck()
		}
	case "quit":
		systray.Quit()
		os.Exit(0)
	}
}

func reader() {
	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scan.Scan() {
		line := scan.Bytes()
		var c trayipc.Cmd
		if err := json.Unmarshal(line, &c); err != nil {
			fmt.Fprintf(os.Stderr, "tray: bad cmd: %v\n", err)
			continue
		}
		handleCmd(c)
	}
}

func main() {
	systray.Run(func() {
		// Default tray click handlers — main uses these to show the window.
		systray.SetOnClick(func(menu systray.IMenu) {
			emit(trayipc.Event{Op: "tray_click"})
		})
		systray.SetOnRClick(func(menu systray.IMenu) {
			menu.ShowMenu()
			emit(trayipc.Event{Op: "tray_rclick"})
		})
		emit(trayipc.Event{Op: "ready"})
		go reader()
	}, func() {
		// Cleanup when systray quits.
	})
}
