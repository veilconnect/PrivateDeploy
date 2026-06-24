package deploy

import (
	"strings"
	"testing"
)

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
