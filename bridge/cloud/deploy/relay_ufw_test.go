package deploy

import (
	"strings"
	"testing"
)

// TestRelayPortUsesUfwAllowNotLimit guards the CDN 522 fix: the relay port must
// be `ufw allow`, not `ufw limit`. All relay traffic arrives from a few
// Cloudflare egress IPs, so `limit` throttles Cloudflare itself → the Worker's
// connect to the origin times out → CF returns 522 → CDN path dies under load.
// Mobile already uses allow; this keeps the desktop deploy in lockstep.
func TestRelayPortUsesUfwAllowNotLimit(t *testing.T) {
	s := GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort: 20000, HysteriaPort: 20001, VLESSPort: 20002, TrojanPort: 20003,
		VLESSRelayPort:  24444,
		VLESSUUID:       "11111111-2222-4333-8444-555555555555",
		VLESSPrivateKey: "k", VLESSPublicKey: "p", VLESSShortID: "0123456789abcdef",
	})
	if strings.Contains(s, "ufw limit 24444/tcp") {
		t.Fatal("relay port must not be rate-limited (ufw limit) — throttles Cloudflare egress → CF 522")
	}
	if !strings.Contains(s, "ufw allow 24444/tcp comment 'VLESS-Relay (CDN)'") {
		t.Fatal("relay port must be `ufw allow` for the CDN Worker origin")
	}
}
