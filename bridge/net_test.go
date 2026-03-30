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

type contextDeadlineExceededStub struct{}

func (contextDeadlineExceededStub) Error() string {
	return "context deadline exceeded"
}

type quotedErrorStub struct{}

func (quotedErrorStub) Error() string {
	return `unexpected "quoted" error`
}
