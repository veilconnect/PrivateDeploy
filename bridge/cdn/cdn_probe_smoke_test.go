// Runtime smoke test for the DoH-bypass probe. Exercises the package-private
// helpers (resolveViaDoH / customHostTLSReachable / customHostRelayReachable)
// against a real Cloudflare Worker custom domain — relay-f2cfd6.example.test,
// the manually-deployed M1 test target. Skipped in short mode and skipped if
// the network can't reach external services so CI doesn't have to think
// about it.
//
// Run locally: `go test -tags=smoke -run TestProbeSmoke ./bridge/cdn/...`

//go:build smoke
// +build smoke

package cdn

import (
	"net"
	"testing"
	"time"
)

const (
	smokeHost = "relay-f2cfd6.example.test"
)

func TestProbeSmoke_ResolveViaDoH(t *testing.T) {
	ips := resolveViaDoH(smokeHost)
	if len(ips) == 0 {
		t.Fatalf("resolveViaDoH(%q) returned no IPs — is the host still bound on CF?", smokeHost)
	}
	t.Logf("resolved %d IPs: %v", len(ips), ips)
	for _, ip := range ips {
		if ip.To4() == nil && ip.To16() == nil {
			t.Errorf("invalid IP %v in DoH answer", ip)
		}
	}
}

func TestProbeSmoke_CustomHostTLSReachable(t *testing.T) {
	ips := resolveViaDoH(smokeHost)
	if len(ips) == 0 {
		t.Skip("DoH resolve failed; can't exercise TLS reach")
	}
	if !customHostTLSReachable(ips, smokeHost, 8*time.Second) {
		t.Fatalf("TLS handshake to %v with SNI=%s failed", ips[0], smokeHost)
	}
}

// Without the real path-secret we can't get a 101, but we can exercise the
// full WS dial path with a wrong secret and confirm the function returns
// false cleanly (instead of panicking, hanging, or returning true). This
// catches regressions in the gorilla/websocket Dialer wiring + NetDialContext
// override even when we don't have the deploy's secret on hand.
func TestProbeSmoke_CustomHostRelayRejectsWrongSecret(t *testing.T) {
	ips := resolveViaDoH(smokeHost)
	if len(ips) == 0 {
		t.Skip("DoH resolve failed; can't exercise WS upgrade")
	}
	// 32 hex chars matching the per-deploy secret shape but not the real value.
	wrongSecret := "deadbeefdeadbeefdeadbeefdeadbeef"
	got := customHostRelayReachable(ips, smokeHost, wrongSecret, 12*time.Second)
	if got {
		t.Fatalf("customHostRelayReachable returned true for a wrong secret — Worker should have 404'd")
	}
}

// Sanity: empty inputs must not blow up.
func TestProbeSmoke_EmptyInputsAreSafe(t *testing.T) {
	if customHostTLSReachable(nil, smokeHost, time.Second) {
		t.Errorf("TLSReachable with nil IPs should be false")
	}
	if customHostRelayReachable([]net.IP{}, smokeHost, "x", time.Second) {
		t.Errorf("RelayReachable with empty IPs should be false")
	}
	if customHostRelayReachable([]net.IP{net.ParseIP("1.2.3.4")}, "", "x", time.Second) {
		t.Errorf("RelayReachable with empty host should be false")
	}
}
