package bridge

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestExpectedSpeedSampleBytes(t *testing.T) {
	if got := expectedSpeedSampleBytes("https://speed.cloudflare.com/__down?bytes=1000000"); got != 1000000 {
		t.Fatalf("expected 1000000 bytes, got %d", got)
	}
	if got := expectedSpeedSampleBytes("https://example.com/test"); got != 0 {
		t.Fatalf("expected 0 bytes for url without bytes query, got %d", got)
	}
}

func TestDefaultSpeedTestURLs(t *testing.T) {
	if len(defaultSpeedTestURLs) < 2 {
		t.Fatalf("expected multiple speed test URLs, got %d", len(defaultSpeedTestURLs))
	}
	if defaultSpeedTestURLs[0] != "https://speed.cloudflare.com/__down?bytes=1000000" {
		t.Fatalf("unexpected primary speed test url: %s", defaultSpeedTestURLs[0])
	}
}

func TestBuildPartialSpeedResult(t *testing.T) {
	result, ok := buildPartialSpeedResult(
		"https://speed.cloudflare.com/__down?bytes=1000000",
		300000,
		5*time.Second,
		contextDeadlineExceededStub{},
	)
	if !ok {
		t.Fatal("expected partial speed result to be accepted")
	}
	if !strings.Contains(result, `"status":"partial"`) {
		t.Fatalf("expected partial status, got %s", result)
	}
	if !strings.Contains(result, `"speedMbps":`) {
		t.Fatalf("expected speedMbps in result, got %s", result)
	}
}

func TestBuildPartialSpeedResultRejectsTinySamples(t *testing.T) {
	if result, ok := buildPartialSpeedResult(
		"https://speed.cloudflare.com/__down?bytes=1000000",
		32000,
		5*time.Second,
		contextDeadlineExceededStub{},
	); ok {
		t.Fatalf("expected tiny sample to be rejected, got %s", result)
	}
}

func TestBuildPartialSpeedResultEscapesErrorMessage(t *testing.T) {
	result, ok := buildPartialSpeedResult(
		"https://speed.cloudflare.com/__down?bytes=1000000",
		300000,
		5*time.Second,
		quotedErrorStub{},
	)
	if !ok {
		t.Fatal("expected partial speed result to be accepted")
	}

	var decoded struct {
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	if err := json.Unmarshal([]byte(result), &decoded); err != nil {
		t.Fatalf("expected valid JSON, got %q: %v", result, err)
	}
	if decoded.Status != "partial" {
		t.Fatalf("status = %q, want partial", decoded.Status)
	}
	if decoded.Error != `unexpected "quoted" error` {
		t.Fatalf("error = %q, want quoted message", decoded.Error)
	}
}

func TestSpeedErrorEscapesJsonErrorMessage(t *testing.T) {
	tests := []struct {
		name string
		msg  string
	}{
		{"simple", "connection refused"},
		{"quotes", `sing-box: "config error"`},
		{"newlines", "line1\nline2\nline3"},
		{"tabs", "field\tvalue"},
		{"backslash", `path\to\file`},
		{"unicode", "错误：连接失败"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := speedError(tt.msg)

			var parsed map[string]interface{}
			if err := json.Unmarshal([]byte(result.Data), &parsed); err != nil {
				t.Fatalf("speedError produced invalid JSON for %q: %v\nRaw: %s", tt.msg, err, result.Data)
			}

			if got := parsed["error"].(string); got != tt.msg {
				t.Errorf("error field mismatch: got %q, want %q", got, tt.msg)
			}
		})
	}
}

func TestIsRetryableSpeedFailure(t *testing.T) {
	tests := []struct {
		message string
		want    bool
	}{
		{"socks connect tcp 127.0.0.1:1080 -> speed.cloudflare.com:443: unknown error general SOCKS server failure", true},
		{"read tcp 127.0.0.1:12345->1.1.1.1:443: i/o timeout", true},
		{"connection refused", true},
		{"certificate signed by unknown authority", false},
		{"", false},
	}

	for _, tt := range tests {
		if got := isRetryableSpeedFailure(tt.message); got != tt.want {
			t.Fatalf("isRetryableSpeedFailure(%q) = %v, want %v", tt.message, got, tt.want)
		}
	}
}

type contextDeadlineExceededStub struct{}

func (contextDeadlineExceededStub) Error() string {
	return "context deadline exceeded"
}

type quotedErrorStub struct{}

func (quotedErrorStub) Error() string {
	return `unexpected "quoted" error`
}
