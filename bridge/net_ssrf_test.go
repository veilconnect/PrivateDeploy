package bridge

import (
	"net"
	"testing"
)

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

func TestSSRFSafeControlAllowLoopback(t *testing.T) {
	// The proxy variant permits the local sing-box (loopback)...
	if err := ssrfSafeControlAllowLoopback("tcp", "127.0.0.1:7890", nil); err != nil {
		t.Fatalf("expected loopback proxy dial to be allowed, got %v", err)
	}
	// ...but still blocks other internal proxy targets.
	if err := ssrfSafeControlAllowLoopback("tcp", "192.168.0.1:8080", nil); err == nil {
		t.Fatal("expected private proxy dial to be blocked")
	}
	if err := ssrfSafeControlAllowLoopback("tcp", "169.254.169.254:80", nil); err == nil {
		t.Fatal("expected metadata proxy dial to be blocked")
	}
}

func TestValidateProxyURL(t *testing.T) {
	allowed := []string{
		"socks5://127.0.0.1:7890",
		"http://localhost:8080",
		"http://proxy.example.com:3128",
	}
	for _, u := range allowed {
		if err := validateProxyURL(u); err != nil {
			t.Errorf("expected proxy %q allowed, got %v", u, err)
		}
	}
	blocked := []string{
		"http://192.168.1.1:3128",
		"socks5://169.254.169.254:1080",
		"http://10.0.0.1:8080",
	}
	for _, u := range blocked {
		if err := validateProxyURL(u); err == nil {
			t.Errorf("expected proxy %q blocked", u)
		}
	}
}

func TestMakeSSRFControlAllowsOnlyConfiguredProxy(t *testing.T) {
	// Explicit loopback proxy: its exact endpoint is dialable, but any other
	// loopback/internal target (e.g. a rebinding host hitting a different port)
	// is still blocked.
	_, allowed := resolveProxy("http://127.0.0.1:7890")
	control := makeSSRFControl(allowed)

	if err := control("tcp", "127.0.0.1:7890", nil); err != nil {
		t.Fatalf("configured proxy endpoint must be dialable, got %v", err)
	}
	if err := control("tcp", "127.0.0.1:9999", nil); err == nil {
		t.Fatal("a different loopback port must be blocked")
	}
	if err := control("tcp", "169.254.169.254:80", nil); err == nil {
		t.Fatal("metadata must be blocked even with a proxy configured")
	}
	if err := control("tcp", "1.1.1.1:443", nil); err != nil {
		t.Fatalf("public target must be allowed, got %v", err)
	}
}

func TestMakeSSRFControlAllowsLocalhostHostnameProxy(t *testing.T) {
	// A proxy given by the "localhost" alias must be dialable: the Control hook
	// sees the resolved loopback IP, not the hostname, so its IPv4/IPv6 loopback
	// resolutions have to be permitted too. Other loopback ports stay blocked.
	_, allowed := resolveProxy("http://localhost:7890")
	control := makeSSRFControl(allowed)

	for _, addr := range []string{"127.0.0.1:7890", "[::1]:7890"} {
		if err := control("tcp", addr, nil); err != nil {
			t.Fatalf("localhost proxy resolution %s must be dialable, got %v", addr, err)
		}
	}
	if err := control("tcp", "127.0.0.1:9999", nil); err == nil {
		t.Fatal("a different loopback port must still be blocked")
	}
}

func TestMakeSSRFControlNoProxyBlocksLoopback(t *testing.T) {
	// No explicit proxy and (assuming) no env proxy → loopback is blocked,
	// closing the NO_PROXY / unparseable-proxy rebinding gap.
	for _, k := range []string{"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"} {
		t.Setenv(k, "")
	}
	_, allowed := resolveProxy("not a valid proxy url ::::")
	control := makeSSRFControl(allowed)
	if err := control("tcp", "127.0.0.1:7890", nil); err == nil {
		t.Fatal("loopback must be blocked when no proxy is actually in effect")
	}
}

func TestCGNATAndBroadcastBlocked(t *testing.T) {
	for _, s := range []string{"100.64.0.1", "100.127.255.254", "255.255.255.255"} {
		if !isBlockedDialIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be blocked", s)
		}
	}
	if isBlockedDialIP(net.ParseIP("100.63.255.255")) {
		t.Error("100.63.255.255 is public, should not be blocked")
	}
}
