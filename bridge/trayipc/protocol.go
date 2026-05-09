// Package trayipc defines the JSON-line protocol between the main Wails
// binary and the privatedeploy-tray sidecar process. The sidecar imports
// systray (and transitively godbus); the main binary does NOT — keeping
// godbus's package init() out of the WebKit/JSC process address space.
package trayipc

// Cmd is sent main → sidecar, one JSON object per line on the sidecar's stdin.
type Cmd struct {
	Op string `json:"op"`

	// op="init"
	Tooltip string `json:"tooltip,omitempty"`
	IconB64 string `json:"icon_b64,omitempty"`

	// op="add_item" / "add_sub_item"
	ID       string `json:"id,omitempty"`
	ParentID string `json:"parent_id,omitempty"`
	Title    string `json:"title,omitempty"`
	Checked  bool   `json:"checked,omitempty"`

	// op="set_icon" / "set_title" / "set_tooltip"
	Value string `json:"value,omitempty"`
}

// Event is sent sidecar → main, one JSON object per line on the sidecar's stdout.
type Event struct {
	Op string `json:"op"`           // "ready", "click", "tray_click", "tray_rclick"
	ID string `json:"id,omitempty"` // for "click"
}
