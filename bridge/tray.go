package bridge

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/wailsapp/wails/v2/pkg/runtime"

	"privatedeploy/bridge/trayipc"
)

// trayProc owns the privatedeploy-tray sidecar. We talk to it via stdin/stdout
// JSON-lines — keeps godbus/systray's package init() out of the main binary's
// address space (where it conflicts with WebKitGTK's JSC initialization).
type trayProc struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	app      *App
	idSeq    atomic.Uint64
	handlers sync.Map // id → func()
}

var tray = &trayProc{}

// CreateTray spawns the sidecar and returns a (start, stop) pair. The start
// function performs the initial menu population once the sidecar reports
// "ready". The signature matches the previous CreateTray so main.go is
// unchanged.
func CreateTray(a *App, icon []byte) (trayStart, trayEnd func()) {
	tray.app = a

	if err := tray.spawn(icon); err != nil {
		log.Printf("[Tray] sidecar spawn failed: %v — running without tray", err)
		return func() {}, func() {}
	}

	start := func() {
		tray.mu.Lock()
		defer tray.mu.Unlock()
		// Default click bindings on the tray icon itself
		tray.send(trayipc.Cmd{Op: "init", Tooltip: "PrivateDeploy", IconB64: encodeIcon(icon)})
		// Fallback menu items in case the frontend never calls UpdateTrayMenus
		tray.addItemLocked("__show", "Show", "Show", false, func() { a.ShowMainWindow() })
		tray.addItemLocked("__restart", "Restart", "Restart", false, func() { a.RestartApp() })
		tray.addItemLocked("__exit", "Exit", "Exit", false, func() { a.ExitApp() })
	}

	stop := func() {
		tray.mu.Lock()
		defer tray.mu.Unlock()
		_ = tray.sendLocked(trayipc.Cmd{Op: "quit"})
	}
	return start, stop
}

func encodeIcon(icon []byte) string {
	if len(icon) == 0 {
		return ""
	}
	return base64.StdEncoding.EncodeToString(icon)
}

func (t *trayProc) spawn(icon []byte) error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	// Look for the sidecar in three places, in order:
	//   1. Same dir as the main binary (deb install: /usr/lib/privatedeploy/)
	//   2. ../lib/privatedeploy/ relative to main binary (AppImage: usr/bin
	//      → usr/lib/privatedeploy/privatedeploy-tray)
	//   3. PATH (dev fallback after `go build ./cmd/privatedeploy-tray`)
	candidates := []string{
		filepath.Join(filepath.Dir(exePath), "privatedeploy-tray"),
		filepath.Join(filepath.Dir(exePath), "..", "lib", "privatedeploy", "privatedeploy-tray"),
	}
	var sidecar string
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			sidecar = c
			break
		}
	}
	if sidecar == "" {
		if p, err := exec.LookPath("privatedeploy-tray"); err == nil {
			sidecar = p
		} else {
			return fmt.Errorf("privatedeploy-tray not found next to %q (searched %v): %w", exePath, candidates, err)
		}
	}

	cmd := exec.Command(sidecar)
	// Strip LD_PRELOAD so the sidecar doesn't inherit the AppImage's
	// webkit_path_rewrite.so shim — it segfaults Go binaries during ld-linux's
	// `_r_debug` setup before main() runs. Also drop the WebKit-bundled
	// LD_LIBRARY_PATH; the sidecar wants the host's standard library path
	// since it links against jammy ABI but its only shared dep is libc.
	env := []string{}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "LD_PRELOAD=") || strings.HasPrefix(kv, "LD_LIBRARY_PATH=") {
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = env
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	t.cmd = cmd
	t.stdin = stdin

	go t.reader(stdout)
	return nil
}

func (t *trayProc) reader(r io.ReadCloser) {
	defer r.Close()
	scan := bufio.NewScanner(r)
	scan.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scan.Scan() {
		var ev trayipc.Event
		if err := json.Unmarshal(scan.Bytes(), &ev); err != nil {
			continue
		}
		switch ev.Op {
		case "click":
			if h, ok := t.handlers.Load(ev.ID); ok {
				go h.(func())()
			}
		case "tray_click":
			if t.app != nil {
				if Env.OS == "darwin" {
					// macOS shows menu on click
				} else {
					t.app.ShowMainWindow()
				}
			}
		}
	}
}

func (t *trayProc) sendLocked(c trayipc.Cmd) error {
	if t.stdin == nil {
		return errors.New("tray sidecar not running")
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = t.stdin.Write(b)
	return err
}

func (t *trayProc) send(c trayipc.Cmd) {
	if err := t.sendLocked(c); err != nil {
		log.Printf("[Tray] send: %v", err)
	}
}

func (t *trayProc) nextID() string {
	return "id" + strconv.FormatUint(t.idSeq.Add(1), 10)
}

func (t *trayProc) addItemLocked(id, title, tooltip string, checked bool, click func()) string {
	if id == "" {
		id = t.nextID()
	}
	t.handlers.Store(id, click)
	t.sendLocked(trayipc.Cmd{Op: "add_item", ID: id, Title: title, Tooltip: tooltip, Checked: checked})
	return id
}

func (t *trayProc) addSubItemLocked(parentID, id, title, tooltip string, checked bool, click func()) string {
	if id == "" {
		id = t.nextID()
	}
	t.handlers.Store(id, click)
	t.sendLocked(trayipc.Cmd{Op: "add_sub_item", ParentID: parentID, ID: id, Title: title, Tooltip: tooltip, Checked: checked})
	return id
}

// UpdateTrayMenus replaces the dynamic menu portion. Called by the frontend.
func (a *App) UpdateTrayMenus(menus []MenuItem) {
	log.Printf("UpdateTrayMenus")
	tray.mu.Lock()
	defer tray.mu.Unlock()
	tray.handlers = sync.Map{}
	tray.send(trayipc.Cmd{Op: "reset_menu"})
	for _, m := range menus {
		tray.createMenuItemLocked(m, a, "")
	}
}

func (t *trayProc) createMenuItemLocked(m MenuItem, a *App, parentID string) {
	if m.Hidden {
		return
	}
	switch m.Type {
	case "item":
		event := m.Event
		click := func() { go runtime.EventsEmit(a.Ctx, "onMenuItemClick", event) }
		var id string
		if parentID == "" {
			id = t.addItemLocked("", m.Text, m.Tooltip, m.Checked, click)
		} else {
			id = t.addSubItemLocked(parentID, "", m.Text, m.Tooltip, m.Checked, click)
		}
		for _, child := range m.Children {
			t.createMenuItemLocked(child, a, id)
		}
	case "separator":
		t.send(trayipc.Cmd{Op: "add_separator"})
	}
}

func (a *App) UpdateTray(traySpec TrayContent) {
	tray.mu.Lock()
	defer tray.mu.Unlock()
	if traySpec.Icon != "" {
		if ico, err := os.ReadFile(GetPath(traySpec.Icon)); err == nil {
			tray.send(trayipc.Cmd{Op: "set_icon", IconB64: encodeIcon(ico)})
		}
	}
	if traySpec.Title != "" {
		tray.send(trayipc.Cmd{Op: "set_title", Value: traySpec.Title})
		runtime.WindowSetTitle(a.Ctx, traySpec.Title)
	}
	if traySpec.Tooltip != "" {
		tray.send(trayipc.Cmd{Op: "set_tooltip", Value: traySpec.Tooltip})
	}
}

func (a *App) ExitApp() {
	tray.mu.Lock()
	tray.send(trayipc.Cmd{Op: "quit"})
	tray.mu.Unlock()
	runtime.Quit(a.Ctx)
	os.Exit(0)
}
