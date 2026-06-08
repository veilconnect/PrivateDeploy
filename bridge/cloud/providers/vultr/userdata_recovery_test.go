package vultr

import (
	"encoding/base64"
	"testing"

	"privatedeploy/bridge/cloud/deploy"
)

func TestDecodeUserDataPayload(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("#!/bin/bash\necho hi"))

	if got := decodeUserDataPayload(map[string]any{
		"user_data": encoded,
	}); got != encoded {
		t.Fatalf("unexpected direct payload: %q", got)
	}

	if got := decodeUserDataPayload(map[string]any{
		"user_data": map[string]any{"data": encoded},
	}); got != encoded {
		t.Fatalf("unexpected nested payload: %q", got)
	}
}

func TestRecoverNodeRecordFromLightweightUserData(t *testing.T) {
	record, ok := recoverNodeRecordFromUserData(
		deploy.GenerateLightweightScript(24443, "light-secret"),
		nodeRecord{},
	)
	if !ok {
		t.Fatalf("expected lightweight recovery to succeed")
	}
	if record.SSPort != 24443 {
		t.Fatalf("unexpected ss port: %d", record.SSPort)
	}
	if record.SSPassword != "light-secret" {
		t.Fatalf("unexpected ss password: %q", record.SSPassword)
	}
}

func TestRecoverNodeRecordFromMultiProtocolUserData(t *testing.T) {
	script := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort:           23951,
		SSPassword:       "ss-secret",
		HysteriaPort:     23952,
		HysteriaPassword: "hy-secret",
		HysteriaServer:   deploy.DefaultHysteriaServerName,
		HysteriaMasqURL:  "https://www.bing.com",
		VLESSPort:        23953,
		VLESSUUID:        "11111111-1111-4111-8111-111111111111",
		VLESSPrivateKey:  "private-key",
		VLESSPublicKey:   "public-key",
		VLESSShortID:     "abcd1234",
		VLESSServer:      deploy.DefaultVLESSServerName,
		TrojanPort:       23954,
		TrojanPassword:   "trojan-secret",
		TrojanServer:     deploy.DefaultTrojanServerName,
		SingBoxVersion:   deploy.DefaultSingBoxVersion,
		SingBoxFallback:  deploy.DefaultSingBoxVersion,
	})

	record, ok := recoverNodeRecordFromUserData(script, nodeRecord{})
	if !ok {
		t.Fatalf("expected multi-protocol recovery to succeed")
	}
	if record.SSPort != 23951 || record.SSPassword != "ss-secret" {
		t.Fatalf("unexpected ss recovery: %+v", record)
	}
	if record.HysteriaPort != 23952 || record.HysteriaPassword != "hy-secret" {
		t.Fatalf("unexpected hysteria recovery: %+v", record)
	}
	if record.VLESSPort != 23953 || record.VLESSUUID != "11111111-1111-4111-8111-111111111111" {
		t.Fatalf("unexpected vless recovery: %+v", record)
	}
	if record.VLESSPublicKey != "public-key" || record.VLESSShortID != "abcd1234" {
		t.Fatalf("unexpected reality recovery: %+v", record)
	}
	if record.TrojanPort != 23954 || record.TrojanPassword != "trojan-secret" {
		t.Fatalf("unexpected trojan recovery: %+v", record)
	}
}
