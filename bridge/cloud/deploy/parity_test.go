package deploy

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// These tests are the single source-of-truth ENFORCEMENT for node provisioning.
// The Go desktop bridge and the Dart mobile app each generate their own deploy
// script (different languages, no shared runtime), and they previously drifted —
// mobile shipped weaker, unversioned nodes. Rather than couple a JSON spec into
// two asset systems at runtime, we assert parity at test time: CI fails the
// moment the security-critical bits diverge.

const (
	dartDeployFile = "../../../mobile/lib/features/cloud/vultr_deploy.dart"
	dartClientFile = "../../../mobile/lib/features/cloud/vultr_client.dart"
)

func readFileOrSkip(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		// The Dart tree may be absent in a Go-only checkout; don't fail there.
		t.Skipf("dart source %s unavailable: %v", path, err)
	}
	return string(b)
}

func dartStringConst(t *testing.T, src, name string) string {
	t.Helper()
	m := regexp.MustCompile(name + `\s*=\s*'([^']*)'`).FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("could not find Dart const %s", name)
	}
	return m[1]
}

// dartStringMap parses a Dart `const Map<String, String> name = { 'k': 'v', ... }`
// literal into a Go map. It only understands single-quoted string keys/values,
// which is all the pin/default maps use.
func dartStringMap(t *testing.T, src, name string) map[string]string {
	t.Helper()
	block := regexp.MustCompile(name + `\s*=\s*\{([^}]*)\}`).FindStringSubmatch(src)
	if block == nil {
		t.Fatalf("could not find Dart map %s", name)
	}
	out := map[string]string{}
	for _, pair := range regexp.MustCompile(`'([^']*)'\s*:\s*'([^']*)'`).FindAllStringSubmatch(block[1], -1) {
		out[pair[1]] = pair[2]
	}
	if len(out) == 0 {
		t.Fatalf("Dart map %s parsed to zero entries", name)
	}
	return out
}

func TestSingBoxVersionParityAcrossEnds(t *testing.T) {
	dart := readFileOrSkip(t, dartDeployFile)
	if got := dartStringConst(t, dart, "defaultSingBoxVersion"); got != DefaultSingBoxVersion {
		t.Fatalf("sing-box version drift: Go=%s Dart=%s — keep policy.go and vultr_deploy.dart in lockstep",
			DefaultSingBoxVersion, got)
	}
	if got := dartStringConst(t, dart, "defaultSingBoxFallbackVersion"); got != DefaultSingBoxFallbackVersion {
		t.Fatalf("sing-box fallback drift: Go=%s Dart=%s", DefaultSingBoxFallbackVersion, got)
	}
}

// TestSingBoxPinParityAcrossEnds is the integrity-critical guard: the SHA-256
// the mobile deploy script verifies the sing-box tarball against MUST be byte-
// identical to the Go pin. A version-string match alone isn't enough — if Go
// rotates a pin (or a typo slips into either map) the version test stays green
// while one end verifies against the wrong hash. We assert the full maps are
// equal in both directions.
func TestSingBoxPinParityAcrossEnds(t *testing.T) {
	dart := readFileOrSkip(t, dartDeployFile)
	dartPins := dartStringMap(t, dart, "singBoxKnownSha256")

	if len(dartPins) != len(singBoxKnownSHA256) {
		t.Fatalf("pin count drift: Go has %d pins, Dart has %d — keep policy.go and vultr_deploy.dart in lockstep",
			len(singBoxKnownSHA256), len(dartPins))
	}
	for version, goHash := range singBoxKnownSHA256 {
		dartHash, ok := dartPins[version]
		if !ok {
			t.Errorf("Dart is missing a sing-box pin for %s that Go pins", version)
			continue
		}
		if dartHash != goHash {
			t.Errorf("sing-box pin drift for %s:\n  Go=%s\n  Dart=%s", version, goHash, dartHash)
		}
	}
	for version := range dartPins {
		if _, ok := singBoxKnownSHA256[version]; !ok {
			t.Errorf("Dart pins sing-box %s that Go does not — an unpinned-on-Go version verifies on mobile only", version)
		}
	}
}

// TestServerNameDefaultParityAcrossEnds keeps the default SNI / camouflage host
// names in lockstep so a node deployed from mobile presents the same TLS
// fingerprint surface as one deployed from the desktop.
func TestServerNameDefaultParityAcrossEnds(t *testing.T) {
	dart := readFileOrSkip(t, dartDeployFile)
	cases := []struct {
		dartConst string
		goValue   string
	}{
		{"defaultHysteriaServerName", DefaultHysteriaServerName},
		{"defaultVlessServerName", DefaultVLESSServerName},
		{"defaultTrojanServerName", DefaultTrojanServerName},
	}
	for _, tc := range cases {
		if got := dartStringConst(t, dart, tc.dartConst); got != tc.goValue {
			t.Errorf("server-name default drift for %s: Go=%s Dart=%s", tc.dartConst, tc.goValue, got)
		}
	}
}

func sampleMultiProtocolScript() string {
	return GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort: 10001, SSPassword: "ss", HysteriaPort: 10002, HysteriaPassword: "hy",
		VLESSPort: 10003, VLESSUUID: "11111111-1111-4111-8111-111111111111",
		VLESSPrivateKey: "k", VLESSPublicKey: "p", VLESSShortID: "0123456789abcdef",
		TrojanPort: 10004, TrojanPassword: "tj",
	})
}

func TestDeployHardeningParityAcrossEnds(t *testing.T) {
	// Markers that must appear in BOTH ends' multi-protocol scripts. Beyond the
	// firewall/integrity anchors, the SSH-hardening sshd_config directives are
	// listed individually so dropping any one on either end fails CI.
	multiMarkers := []string{
		"fail2ban", "ufw limit 22/tcp", "99-privatedeploy.conf", "verify_checksum", "SKIP_SINGBOX",
		"PermitEmptyPasswords", "MaxAuthTries", "NoNewPrivileges", "X11Forwarding", "ClientAliveInterval",
	}
	goMulti := sampleMultiProtocolScript()
	dartMulti := readFileOrSkip(t, dartDeployFile)
	for _, m := range multiMarkers {
		if !strings.Contains(goMulti, m) {
			t.Errorf("Go multi-protocol script missing hardening marker %q", m)
		}
		if !strings.Contains(dartMulti, m) {
			t.Errorf("Dart multi-protocol script missing hardening marker %q", m)
		}
	}

	// Lightweight scripts (Shadowsocks-only) must carry the SSH/fail2ban hardening too.
	lightMarkers := []string{"fail2ban", "ufw limit 22/tcp", "99-privatedeploy.conf"}
	goLight := GenerateLightweightScript(10001, "pw")
	dartLight := readFileOrSkip(t, dartClientFile)
	for _, m := range lightMarkers {
		if !strings.Contains(goLight, m) {
			t.Errorf("Go lightweight script missing hardening marker %q", m)
		}
		if !strings.Contains(dartLight, m) {
			t.Errorf("Dart lightweight script missing hardening marker %q", m)
		}
	}
}
