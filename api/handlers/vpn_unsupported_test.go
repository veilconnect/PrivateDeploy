package handlers

import (
	"errors"
	"testing"
)

func TestUnsupportedVPNManagerReturnsCapabilityError(t *testing.T) {
	manager := NewUnsupportedVPNManager("test runtime is unavailable")

	for name, call := range map[string]func() error{
		"start":      func() error { return manager.Start("default") },
		"stop":       manager.Stop,
		"restart":    manager.Restart,
		"resetStats": manager.ResetStats,
	} {
		if err := call(); !errors.Is(err, ErrVPNUnsupported) {
			t.Fatalf("%s should wrap ErrVPNUnsupported, got %v", name, err)
		}
	}

	if _, err := manager.GetStatus(); !errors.Is(err, ErrVPNUnsupported) {
		t.Fatalf("GetStatus should wrap ErrVPNUnsupported, got %v", err)
	}

	if _, err := manager.GetStats(); !errors.Is(err, ErrVPNUnsupported) {
		t.Fatalf("GetStats should wrap ErrVPNUnsupported, got %v", err)
	}
}
