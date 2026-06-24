package cloud

import "testing"

func TestEnsureManagedTLSDefaults(t *testing.T) {
	r := &InstanceRecord{
		HysteriaPort: 20002, HysteriaPassword: "hy",
		TrojanPort: 20004, TrojanPassword: "tj",
		VLESSPort: 20003, VLESSUUID: "11111111-1111-4111-8111-111111111111",
	}
	if !EnsureManagedTLSDefaults(r) {
		t.Fatal("expected defaults to be backfilled")
	}
	if r.HysteriaServerName == "" || r.TrojanServerName == "" || r.VLESSServerName == "" {
		t.Fatalf("server names not backfilled: %+v", r)
	}
	if r.HysteriaInsecure == nil || !*r.HysteriaInsecure {
		t.Fatal("hysteria insecure default not set")
	}
	// VLESS reuses the Trojan server name when present.
	if r.VLESSServerName != r.TrojanServerName {
		t.Fatalf("VLESS should inherit Trojan server name; got %q vs %q", r.VLESSServerName, r.TrojanServerName)
	}
	// Idempotent: a second pass changes nothing.
	if EnsureManagedTLSDefaults(r) {
		t.Fatal("second pass should be a no-op")
	}
}

func TestHasMinimumProxyConfig(t *testing.T) {
	if HasMinimumProxyConfig(InstanceRecord{}) {
		t.Fatal("empty record must be incomplete")
	}
	if !HasMinimumProxyConfig(InstanceRecord{SSPort: 1080, SSPassword: "p"}) {
		t.Fatal("SS port+password should be the minimum valid config")
	}
	// Legacy Port mirror must agree with SSPort.
	if HasMinimumProxyConfig(InstanceRecord{SSPort: 1080, SSPassword: "p", Port: 9999}) {
		t.Fatal("mismatched legacy Port must invalidate the record")
	}
}
