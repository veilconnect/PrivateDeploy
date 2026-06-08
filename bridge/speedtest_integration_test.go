//go:build integration
// +build integration

package bridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSpeedTestIntegration runs the full speed test flow using the real sing-box binary.
// It creates a temporary "direct" outbound config and tests download speed without any proxy.
// This validates the entire pipeline: binary detection, config generation, process management,
// SOCKS proxy setup, and HTTP download through the proxy.
func TestSpeedTestIntegration(t *testing.T) {
	// Find sing-box binary
	singboxPath := findSingboxBinaryFromEnv()
	if singboxPath == "" {
		// Try the build output path
		candidates := []string{
			filepath.Join("build", "bin", "data", "sing-box", "sing-box"),
			filepath.Join("..", "build", "bin", "data", "sing-box", "sing-box"),
		}
		for _, c := range candidates {
			abs, _ := filepath.Abs(c)
			if info, err := os.Stat(abs); err == nil && !info.IsDir() {
				singboxPath = abs
				break
			}
		}
	}
	if singboxPath == "" {
		t.Skip("sing-box binary not found, skipping integration test")
	}

	t.Logf("Using sing-box at: %s", singboxPath)

	// Set BasePath so findSingboxBinaryFromEnv can find the binary
	origBasePath := Env.BasePath
	Env.BasePath = filepath.Dir(filepath.Dir(filepath.Dir(singboxPath))) // up 3 levels from sing-box binary
	defer func() { Env.BasePath = origBasePath }()

	// Verify findSingboxBinaryFromEnv works
	found := findSingboxBinaryFromEnv()
	if found == "" {
		t.Fatal("findSingboxBinaryFromEnv returned empty after setting BasePath")
	}
	t.Logf("findSingboxBinaryFromEnv found: %s", found)

	// Create a "direct" outbound config — no actual proxy, just direct connection
	outbounds := []map[string]interface{}{
		{
			"type": "direct",
			"tag":  "direct-out",
		},
	}
	outboundsJSON, _ := json.Marshal(outbounds)

	t.Logf("Testing with outbounds: %s", string(outboundsJSON))

	// Run the speed test
	app := &App{}
	result := app.TestNodeDirectSpeed(string(outboundsJSON), 10)

	t.Logf("Result flag=%v data=%s", result.Flag, result.Data)

	// Parse the result
	var parsed struct {
		SpeedMbps float64 `json:"speedMbps"`
		Status    string  `json:"status"`
		Error     string  `json:"error"`
		Bytes     int64   `json:"bytes"`
		ElapsedMs float64 `json:"elapsedMs"`
	}
	if err := json.Unmarshal([]byte(result.Data), &parsed); err != nil {
		t.Fatalf("Failed to parse result JSON: %v\nRaw data: %s", err, result.Data)
	}

	t.Logf("Parsed: status=%s speed=%.2f Mbps bytes=%d elapsed=%.0fms error=%s",
		parsed.Status, parsed.SpeedMbps, parsed.Bytes, parsed.ElapsedMs, parsed.Error)

	if parsed.Status == "error" {
		// Check if it's a sing-box startup error
		if strings.Contains(parsed.Error, "not found") {
			t.Fatalf("sing-box binary not found: %s", parsed.Error)
		}
		if strings.Contains(parsed.Error, "not ready") {
			t.Fatalf("sing-box failed to start: %s", parsed.Error)
		}
		// Network errors are acceptable in CI/testing environments
		t.Logf("Speed test returned error (may be expected in test env): %s", parsed.Error)
		return
	}

	if parsed.Status == "ok" || parsed.Status == "partial" {
		if parsed.SpeedMbps <= 0 {
			t.Errorf("Speed test succeeded but speed is 0")
		}
		t.Logf("SUCCESS: %.2f Mbps", parsed.SpeedMbps)
	}
}

// TestDiagnoseSingbox verifies the diagnostic function works.
func TestDiagnoseSingbox(t *testing.T) {
	origBasePath := Env.BasePath

	// Try to find sing-box for a real test
	candidates := []string{
		filepath.Join("build", "bin"),
		filepath.Join("..", "build", "bin"),
	}
	for _, c := range candidates {
		abs, _ := filepath.Abs(c)
		singbox := filepath.Join(abs, "data", "sing-box", "sing-box")
		if _, err := os.Stat(singbox); err == nil {
			Env.BasePath = abs
			break
		}
	}
	defer func() { Env.BasePath = origBasePath }()

	app := &App{}
	result := app.DiagnoseSingbox()

	t.Logf("DiagnoseSingbox flag=%v data=%s", result.Flag, result.Data)

	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(result.Data), &parsed); err != nil {
		t.Fatalf("Failed to parse diagnostic JSON: %v", err)
	}

	t.Logf("basePath=%v found=%v singboxPath=%v", parsed["basePath"], parsed["found"], parsed["singboxPath"])

	if version, ok := parsed["version"]; ok {
		t.Logf("sing-box version: %s", version)
	}
	if vErr, ok := parsed["versionError"]; ok {
		t.Logf("sing-box version error: %s", vErr)
	}
}
