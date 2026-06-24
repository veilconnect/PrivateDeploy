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

func sampleMultiProtocolScript() string {
	return GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort: 10001, SSPassword: "ss", HysteriaPort: 10002, HysteriaPassword: "hy",
		VLESSPort: 10003, VLESSUUID: "11111111-1111-4111-8111-111111111111",
		VLESSPrivateKey: "k", VLESSPublicKey: "p", VLESSShortID: "0123456789abcdef",
		TrojanPort: 10004, TrojanPassword: "tj",
	})
}

func TestDeployHardeningParityAcrossEnds(t *testing.T) {
	// Markers that must appear in BOTH ends' multi-protocol scripts.
	multiMarkers := []string{"fail2ban", "ufw limit 22/tcp", "99-privatedeploy.conf", "verify_checksum", "SKIP_SINGBOX"}
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
