package provutil

import (
	"testing"
	"time"
)

func TestMergeExtraDropsBlankKeysAndOverrides(t *testing.T) {
	base := map[string]string{"a": "1", "b": "2", "  ": "blank", "": "empty"}
	override := map[string]string{"b": "override", "c": "3"}
	got := MergeExtra(base, override)

	want := map[string]string{"a": "1", "b": "override", "c": "3"}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d (%v)", len(got), len(want), got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q = %q, want %q", k, got[k], v)
		}
	}
	if _, ok := got["  "]; ok {
		t.Error("blank whitespace key should be dropped")
	}
	if _, ok := got[""]; ok {
		t.Error("empty key should be dropped")
	}
}

func TestGenerateShortID(t *testing.T) {
	a := GenerateShortID()
	if len(a) != 16 {
		t.Fatalf("len = %d, want 16 (%q)", len(a), a)
	}
	for _, r := range a {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			t.Fatalf("non-hex rune %q in %q", r, a)
		}
	}
	if b := GenerateShortID(); a == b {
		t.Errorf("two short IDs collided: %q", a)
	}
}

func TestParseServiceReadyTimeout(t *testing.T) {
	fallback := 90 * time.Second
	cases := []struct {
		name  string
		extra map[string]string
		want  time.Duration
	}{
		{"nil falls back", nil, fallback},
		{"camelCase", map[string]string{"serviceReadyTimeoutSec": "30"}, 30 * time.Second},
		{"snake_case", map[string]string{"service_ready_timeout_sec": "45"}, 45 * time.Second},
		{"legacy proxy key", map[string]string{"proxyReadyTimeoutSec": "10"}, 10 * time.Second},
		{"non-positive falls back", map[string]string{"serviceReadyTimeoutSec": "0"}, fallback},
		{"garbage falls back", map[string]string{"serviceReadyTimeoutSec": "abc"}, fallback},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ParseServiceReadyTimeout(tc.extra, fallback); got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestUniquePositivePorts(t *testing.T) {
	got := UniquePositivePorts([]int{443, 0, 443, -1, 8080, 8080})
	want := []int{443, 8080}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	if UniquePositivePorts(nil) != nil {
		t.Error("nil input should yield nil")
	}
}

func TestPortsToCSV(t *testing.T) {
	if got := PortsToCSV([]int{1, 22, 443}); got != "1,22,443" {
		t.Errorf("got %q, want %q", got, "1,22,443")
	}
	if got := PortsToCSV(nil); got != "" {
		t.Errorf("nil should yield empty string, got %q", got)
	}
}

func TestPendingTCPPortsBlankIP(t *testing.T) {
	ports := []int{443}
	if got := PendingTCPPorts("", ports, time.Millisecond); len(got) != 1 || got[0] != 443 {
		t.Errorf("blank ip should return ports unchanged, got %v", got)
	}
}
