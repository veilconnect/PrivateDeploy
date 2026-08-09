package vultr

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

func useShortVultrRepairTimeouts(t *testing.T) {
	t.Helper()
	oldInitial := repairInitialProbeTimeout
	oldPostSSH := repairPostSSHProbeTimeout
	oldSettle := repairRebootSettleDelay
	oldReboot := repairRebootProbeTimeout
	repairInitialProbeTimeout = 25 * time.Millisecond
	repairPostSSHProbeTimeout = 250 * time.Millisecond
	repairRebootSettleDelay = time.Millisecond
	repairRebootProbeTimeout = 25 * time.Millisecond
	t.Cleanup(func() {
		repairInitialProbeTimeout = oldInitial
		repairPostSSHProbeTimeout = oldPostSSH
		repairRebootSettleDelay = oldSettle
		repairRebootProbeTimeout = oldReboot
	})
}

func closedLocalTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

type repairAPICounters struct {
	instanceCreates atomic.Int32
	instanceGets    atomic.Int32
	reboots         atomic.Int32
	sshKeyReads     atomic.Int32
}

func installRepairAPIServer(t *testing.T, instanceID string, port int, ownershipToken, defaultPassword string) *repairAPICounters {
	t.Helper()
	counters := &repairAPICounters{}
	description := managedFirewallDescription(instanceID, ownershipToken)
	useVultrTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/instances/"+instanceID:
			counters.instanceGets.Add(1)
			instance := map[string]any{
				"id": instanceID, "label": "repair-node", "status": "active", "region": "ewr",
				"plan": "vc2-1c-1gb", "main_ip": "127.0.0.1",
			}
			if defaultPassword != "" {
				instance["default_password"] = defaultPassword
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"instance": instance})
		case r.Method == http.MethodGet && r.URL.Path == "/plans":
			_, _ = w.Write([]byte(`{"plans":[{"id":"vc2-1c-1gb","ram":512}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/firewalls":
			_ = json.NewEncoder(w).Encode(map[string]any{"firewall_groups": []map[string]any{{
				"id": "fw-repair", "description": description,
			}}})
		case r.Method == http.MethodGet && r.URL.Path == "/firewalls/fw-repair/rules":
			_ = json.NewEncoder(w).Encode(map[string]any{"firewall_rules": []map[string]any{
				{"ip_type": "v4", "protocol": "tcp", "subnet": "0.0.0.0", "subnet_size": 0, "port": "22"},
				{"ip_type": "v4", "protocol": "tcp", "subnet": "0.0.0.0", "subnet_size": 0, "port": strconv.Itoa(port)},
				{"ip_type": "v4", "protocol": "udp", "subnet": "0.0.0.0", "subnet_size": 0, "port": strconv.Itoa(port)},
			}})
		case r.Method == http.MethodPatch && r.URL.Path == "/instances/"+instanceID:
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPost && r.URL.Path == "/instances/"+instanceID+"/reboot":
			counters.reboots.Add(1)
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPost && r.URL.Path == "/instances":
			counters.instanceCreates.Add(1)
			http.Error(w, "repair must not create", http.StatusInternalServerError)
		case r.Method == http.MethodGet && r.URL.Path == "/ssh-keys":
			counters.sshKeyReads.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{"ssh_keys": []vultrAccountSSHKey{}})
		default:
			http.NotFound(w, r)
		}
	}))
	return counters
}

func newRepairProvider(t *testing.T, instanceID string, port int, ownershipToken, fingerprint string) *Provider {
	t.Helper()
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})
	err := provider.persistNodeRecord(instanceID, nodeRecord{
		InstanceID:               instanceID,
		Label:                    "repair-node",
		Region:                   "ewr",
		ManagedSSHKeyFingerprint: fingerprint,
		FirewallOwnershipToken:   ownershipToken,
		FirewallGroupID:          "fw-repair",
		InstanceRecord: cloud.InstanceRecord{
			Plan: "vc2-1c-1gb", IPv4: "127.0.0.1", SSPort: port, SSPassword: "node-secret",
			LastDeployWarning: "service readiness failed: old warning",
		},
	})
	if err != nil {
		t.Fatalf("persist repair node: %v", err)
	}
	return provider
}

func TestRepairInstanceRerunsManagedDeploymentOnSameNode(t *testing.T) {
	useShortVultrRepairTimeouts(t)
	const instanceID = "51111111-2222-4333-8444-555555555555"
	port := closedLocalTCPPort(t)
	privatePEM, _, fingerprint := generateVultrManagedKeyForTest(t)
	provider := newRepairProvider(t, instanceID, port, "owner-managed", fingerprint)
	if err := cloud.SaveSecret(provider.configPath, managedSSHKeyScope, privatePEM); err != nil {
		t.Fatalf("save managed key: %v", err)
	}
	const passwordCanary = "managed-path-must-not-use-this-password"
	counters := installRepairAPIServer(t, instanceID, port, "owner-managed", passwordCanary)

	var repairedListener net.Listener
	provider.runManagedSSHRepair = func(ctx context.Context, ip, receivedPrivatePEM string) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if ip != "127.0.0.1" || receivedPrivatePEM != privatePEM {
			return errors.New("unexpected managed SSH repair inputs")
		}
		listener, err := net.Listen("tcp", net.JoinHostPort(ip, strconv.Itoa(port)))
		if err != nil {
			return err
		}
		repairedListener = listener
		return nil
	}
	t.Cleanup(func() {
		if repairedListener != nil {
			_ = repairedListener.Close()
		}
	})

	instance, err := provider.RepairInstance(context.Background(), instanceID)
	if err != nil {
		t.Fatalf("RepairInstance: %v", err)
	}
	if instance == nil || instance.ID != instanceID || instance.LastDeployWarning != "" {
		t.Fatalf("unexpected repaired instance: %#v", instance)
	}
	if got := counters.reboots.Load(); got != 0 {
		t.Fatalf("healthy-after-SSH repair reboot count=%d, want 0", got)
	}
	if got := counters.instanceCreates.Load(); got != 0 {
		t.Fatalf("repair POST /instances count=%d, want 0", got)
	}
	if got := counters.sshKeyReads.Load(); got != 0 {
		t.Fatalf("repair GET /ssh-keys count=%d, want 0 account-key mutations/lookups", got)
	}
	if got := counters.instanceGets.Load(); got != 2 {
		t.Fatalf("managed repair instance GET count=%d, want initial and final GET only", got)
	}
}

func TestRepairInstanceNeverUsesVultrDefaultPassword(t *testing.T) {
	useShortVultrRepairTimeouts(t)
	const (
		instanceID = "61111111-2222-4333-8444-555555555555"
		password   = "vultr-root-password-must-never-enter-repair"
	)
	port := closedLocalTCPPort(t)
	provider := newRepairProvider(t, instanceID, port, "owner-password-ignored", "")
	counters := installRepairAPIServer(t, instanceID, port, "owner-password-ignored", password)
	provider.runManagedSSHRepair = func(context.Context, string, string) error {
		t.Fatal("legacy node must not attempt managed-key SSH")
		return nil
	}

	instance, err := provider.RepairInstance(context.Background(), instanceID)
	if err == nil || instance != nil {
		t.Fatalf("expected bounded legacy repair failure, instance=%#v err=%v", instance, err)
	}
	if strings.Contains(err.Error(), password) {
		t.Fatalf("Vultr default password leaked through repair error: %v", err)
	}
	if !strings.Contains(err.Error(), "unsafe password handoff") ||
		!strings.Contains(err.Error(), "no replacement instance was created") {
		t.Fatalf("repair error is not explicit about the safe legacy limitation: %v", err)
	}
	// Repair reads the instance once for its normal metadata. A second GET used
	// to fetch default_password would violate the password-free repair boundary.
	if got := counters.instanceGets.Load(); got != 1 {
		t.Fatalf("legacy repair instance GET count=%d, want exactly 1", got)
	}
	if got := counters.reboots.Load(); got != 1 {
		t.Fatalf("same-node reboot count=%d, want 1", got)
	}
	if got := counters.instanceCreates.Load(); got != 0 {
		t.Fatalf("repair POST /instances count=%d, want 0", got)
	}
	records, loadErr := provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	encodedRecords, marshalErr := json.Marshal(records)
	if marshalErr != nil {
		t.Fatal(marshalErr)
	}
	onDisk, readErr := os.ReadFile(provider.nodesPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if strings.Contains(string(encodedRecords), password) || strings.Contains(string(onDisk), password) {
		t.Fatal("Vultr default password was persisted in node state")
	}
}

func TestRepairInstanceLegacyNodeFailsFastWithoutReplacement(t *testing.T) {
	useShortVultrRepairTimeouts(t)
	const instanceID = "71111111-2222-4333-8444-555555555555"
	port := closedLocalTCPPort(t)
	provider := newRepairProvider(t, instanceID, port, "owner-legacy", "")
	counters := installRepairAPIServer(t, instanceID, port, "owner-legacy", "")
	provider.runManagedSSHRepair = func(context.Context, string, string) error {
		t.Fatal("legacy node must not attempt managed SSH")
		return nil
	}

	started := time.Now()
	instance, err := provider.RepairInstance(context.Background(), instanceID)
	if err == nil || instance != nil {
		t.Fatalf("expected bounded legacy repair failure, instance=%#v err=%v", instance, err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("legacy repair exceeded test's bounded window: %v", elapsed)
	}
	if !strings.Contains(err.Error(), "unsafe password handoff") || !strings.Contains(err.Error(), "no replacement instance was created") {
		t.Fatalf("repair error is not explicit: %v", err)
	}
	if got := counters.reboots.Load(); got != 1 {
		t.Fatalf("same-node reboot count=%d, want 1", got)
	}
	if got := counters.instanceCreates.Load(); got != 0 {
		t.Fatalf("repair POST /instances count=%d, want 0", got)
	}
	records, loadErr := provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	if !strings.Contains(records[instanceID].LastDeployWarning, "no replacement instance was created") {
		t.Fatalf("explicit warning was not persisted: %q", records[instanceID].LastDeployWarning)
	}
}

func TestRerunManagedDeploymentRejectsChangedPrivateKey(t *testing.T) {
	const instanceID = "inst-key-mismatch"
	port := closedLocalTCPPort(t)
	privatePEM, _, _ := generateVultrManagedKeyForTest(t)
	_, _, oldFingerprint := generateVultrManagedKeyForTest(t)
	provider := newRepairProvider(t, instanceID, port, "owner-mismatch", oldFingerprint)
	if err := cloud.SaveSecret(provider.configPath, managedSSHKeyScope, privatePEM); err != nil {
		t.Fatal(err)
	}
	installRepairAPIServer(t, instanceID, port, "owner-mismatch", "password-must-not-be-used")
	provider.runManagedSSHRepair = func(context.Context, string, string) error {
		t.Fatal("mismatched private key must never be sent to the node")
		return nil
	}

	eligible, err := provider.rerunManagedDeployment(context.Background(), instanceID, "127.0.0.1")
	if !eligible || err == nil || !strings.Contains(err.Error(), "no longer matches") {
		t.Fatalf("eligible=%v err=%v, want safe fingerprint rejection", eligible, err)
	}
}
