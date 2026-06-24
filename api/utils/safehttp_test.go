package utils

import (
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestValidateOutboundURL(t *testing.T) {
	blocked := []string{
		"http://127.0.0.1/sub",
		"http://localhost:8080/sub",
		"http://169.254.169.254/latest/meta-data/", // cloud metadata
		"http://10.0.0.5/sub",                       // RFC1918
		"http://192.168.1.1/sub",                    // RFC1918
		"http://100.64.0.1/sub",                     // CGNAT
		"http://[::1]/sub",                          // IPv6 loopback
		"ftp://example.com/sub",                     // unsupported scheme
		"file:///etc/passwd",                        // unsupported scheme
		"   ",                                       // empty host
	}
	for _, u := range blocked {
		if err := ValidateOutboundURL(u); err == nil {
			t.Errorf("expected %q to be blocked, but it was allowed", u)
		}
	}

	allowed := []string{
		"https://example.com/subscribe",
		"http://example.com:8443/sub",
		"http://93.184.216.34/sub", // public IP literal
	}
	for _, u := range allowed {
		if err := ValidateOutboundURL(u); err != nil {
			t.Errorf("expected %q to be allowed, got %v", u, err)
		}
	}
}

func TestSSRFSafeClientBlocksInternalIPAtDial(t *testing.T) {
	client := SSRFSafeClient(5 * time.Second)
	// A literal internal IP skips DNS, so the dial-time Control hook is the
	// thing under test here. The request must fail closed.
	req, err := http.NewRequest(http.MethodGet, "http://169.254.169.254/latest/", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if resp != nil {
		resp.Body.Close()
	}
	if err == nil {
		t.Fatal("expected dial to 169.254.169.254 to be blocked, but the request succeeded")
	}
	if !errors.Is(err, ErrBlockedOutboundURL) {
		t.Fatalf("expected ErrBlockedOutboundURL, got %v", err)
	}
}
