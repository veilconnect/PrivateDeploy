package cloud

import (
	"testing"

	"privatedeploy/bridge/cloud/deploy"
)

func TestRecoverInstanceRecordFromLightweightUserData(t *testing.T) {
	var rec InstanceRecord
	if !RecoverInstanceRecordFromUserData(deploy.GenerateLightweightScript(24443, "light-secret"), &rec) {
		t.Fatal("expected lightweight recovery to succeed")
	}
	if rec.SSPort != 24443 || rec.SSPassword != "light-secret" {
		t.Fatalf("unexpected ss recovery: %+v", rec)
	}
}

func TestRecoverInstanceRecordFromMultiProtocolUserData(t *testing.T) {
	script := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort: 23951, SSPassword: "ss-secret",
		HysteriaPort: 23952, HysteriaPassword: "hy-secret",
		HysteriaServer: deploy.DefaultHysteriaServerName, HysteriaMasqURL: "https://www.bing.com",
		VLESSPort: 23953, VLESSUUID: "11111111-1111-4111-8111-111111111111",
		VLESSPrivateKey: "private-key", VLESSPublicKey: "public-key", VLESSShortID: "abcd1234",
		VLESSServer: deploy.DefaultVLESSServerName,
		TrojanPort:  23954, TrojanPassword: "trojan-secret", TrojanServer: deploy.DefaultTrojanServerName,
		SingBoxVersion: deploy.DefaultSingBoxVersion, SingBoxFallback: deploy.DefaultSingBoxFallbackVersion,
	})

	var rec InstanceRecord
	if !RecoverInstanceRecordFromUserData(script, &rec) {
		t.Fatal("expected multi-protocol recovery to succeed")
	}
	if rec.SSPort != 23951 || rec.SSPassword != "ss-secret" {
		t.Fatalf("ss: %+v", rec)
	}
	if rec.HysteriaPort != 23952 || rec.HysteriaPassword != "hy-secret" {
		t.Fatalf("hysteria: %+v", rec)
	}
	if rec.VLESSPort != 23953 || rec.VLESSUUID != "11111111-1111-4111-8111-111111111111" {
		t.Fatalf("vless: %+v", rec)
	}
	if rec.VLESSPublicKey != "public-key" || rec.VLESSShortID != "abcd1234" {
		t.Fatalf("reality: %+v", rec)
	}
	if rec.TrojanPort != 23954 || rec.TrojanPassword != "trojan-secret" {
		t.Fatalf("trojan: %+v", rec)
	}
}

func TestRecoverInstanceRecordRejectsGarbage(t *testing.T) {
	var rec InstanceRecord
	if RecoverInstanceRecordFromUserData("#!/bin/bash\necho nothing useful here\n", &rec) {
		t.Fatal("expected recovery to fail on a script with no proxy config")
	}
}
