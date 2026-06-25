package deploy

import (
	"regexp"
	"strings"
	"testing"
)

// TestDefaultSingBoxVersionsArePinned guards against the version-bump footgun:
// bumping DefaultSingBoxVersion / DefaultSingBoxFallbackVersion without adding
// the matching entry to singBoxKnownSHA256 would silently downgrade the deploy
// integrity check to "skip verification" (an empty pin). This fails the build
// instead, mirroring the Dart-side assertion in vultr_deploy_test.dart.
func TestDefaultSingBoxVersionsArePinned(t *testing.T) {
	hex64 := regexp.MustCompile(`^[0-9a-f]{64}$`)
	for _, v := range []string{DefaultSingBoxVersion, DefaultSingBoxFallbackVersion} {
		h := SingBoxSHA256(v)
		if !hex64.MatchString(h) {
			t.Fatalf("sing-box %q has no pinned SHA-256 (got %q) — add it to singBoxKnownSHA256 when bumping the default version", v, h)
		}
	}
}

func TestResolveDeploymentTuningDefaultsSupportHysteriaMasquerade(t *testing.T) {
	tuning := ResolveDeploymentTuning(nil)

	if tuning.SingBoxVersion != "1.12.12" {
		t.Fatalf("unexpected default sing-box version: %s", tuning.SingBoxVersion)
	}
	if tuning.SingBoxFallbackVersion != "1.11.0" {
		t.Fatalf("unexpected default sing-box fallback version: %s", tuning.SingBoxFallbackVersion)
	}
	if tuning.HysteriaMasqueradeURL == "" {
		t.Fatal("expected default hysteria masquerade URL to be set")
	}
}

func TestGenerateMultiProtocolScriptUsesDefaultSingBoxVersion(t *testing.T) {
	script := GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort:           10001,
		SSPassword:       "ss-pass",
		HysteriaPort:     10002,
		HysteriaPassword: "hy-pass",
		VLESSPort:        10003,
		VLESSUUID:        "11111111-1111-4111-8111-111111111111",
		VLESSPrivateKey:  "private-key",
		VLESSPublicKey:   "public-key",
		VLESSShortID:     "0123456789abcdef",
		TrojanPort:       10004,
		TrojanPassword:   "trojan-pass",
	})

	if !strings.Contains(script, "SINGBOX_VERSION=\"1.12.12\"") {
		t.Fatal("expected deployment script to set sing-box v1.12.12 by default")
	}
	if !strings.Contains(script, "\"masquerade\"") {
		t.Fatal("expected deployment script to include hysteria masquerade configuration")
	}
}
