package bridge

import "testing"

func TestValidateOutboundURL(t *testing.T) {
	blocked := []string{
		"http://127.0.0.1/",
		"http://localhost:8080/x",
		"https://169.254.169.254/latest/meta-data/",
		"http://10.0.0.5/",
		"http://192.168.1.1/",
		"http://172.16.0.1/",
		"http://[::1]/",
		"ftp://example.com/",
		"file:///etc/passwd",
		"http://0.0.0.0/",
		"",
	}
	for _, u := range blocked {
		if err := validateOutboundURL(u); err == nil {
			t.Errorf("expected %q to be blocked", u)
		}
	}

	allowed := []string{
		"https://speed.cloudflare.com/__down?bytes=1000000",
		"https://api.vultr.com/v2/instances",
		"http://example.com:8443/path",
	}
	for _, u := range allowed {
		if err := validateOutboundURL(u); err != nil {
			t.Errorf("expected %q to be allowed, got %v", u, err)
		}
	}
}

func TestSSRFSafeControlBlocksInternalIP(t *testing.T) {
	if err := ssrfSafeControl("tcp", "169.254.169.254:80", nil); err == nil {
		t.Fatal("expected metadata IP dial to be blocked")
	}
	if err := ssrfSafeControl("tcp", "10.1.2.3:443", nil); err == nil {
		t.Fatal("expected private IP dial to be blocked")
	}
	if err := ssrfSafeControl("tcp", "1.1.1.1:443", nil); err != nil {
		t.Fatalf("expected public IP dial to be allowed, got %v", err)
	}
}
