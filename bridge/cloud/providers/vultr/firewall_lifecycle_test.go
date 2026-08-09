package vultr

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

type firewallFakeAPI struct {
	mu sync.Mutex

	groups               map[string]vultrFirewallGroup
	rules                map[string][]vultrFirewallRule
	attachments          map[string]string
	instances            []vultrInstance
	liveInstanceLookups  map[string]bool
	deletedGroups        []string
	deletedInstances     []string
	createCalls          int
	ruleCreateCalls      int
	groupDelete404       map[string]bool
	firewallListFailures int
	instanceListFailures int
	nextID               int
	createdMaxRules      int
}

func newFirewallFakeAPI() *firewallFakeAPI {
	return &firewallFakeAPI{
		groups:              make(map[string]vultrFirewallGroup),
		rules:               make(map[string][]vultrFirewallRule),
		attachments:         make(map[string]string),
		liveInstanceLookups: make(map[string]bool),
		groupDelete404:      make(map[string]bool),
		createdMaxRules:     50,
	}
}

func (f *firewallFakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")

	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/firewalls":
		if f.firewallListFailures > 0 {
			f.firewallListFailures--
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"message":"temporary firewall list failure"}}`))
			return
		}
		groups := make([]vultrFirewallGroup, 0, len(f.groups))
		for _, group := range f.groups {
			group.RuleCount = len(f.rules[group.ID])
			groups = append(groups, group)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"firewall_groups": groups})
		return

	case r.Method == http.MethodGet && r.URL.Path == "/instances":
		if f.instanceListFailures > 0 {
			f.instanceListFailures--
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"message":"temporary instance list failure"}}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"instances": f.instances})
		return

	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/instances/"):
		instanceID := strings.TrimPrefix(r.URL.Path, "/instances/")
		if f.liveInstanceLookups[instanceID] {
			_ = json.NewEncoder(w).Encode(map[string]any{"instance": map[string]any{"id": instanceID, "status": "active"}})
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"message":"not found"}}`))
		return

	case r.Method == http.MethodPost && r.URL.Path == "/firewalls":
		f.createCalls++
		var payload struct {
			Description string `json:"description"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		f.nextID++
		id := fmt.Sprintf("fw-%d", f.nextID)
		group := vultrFirewallGroup{ID: id, Description: payload.Description, MaxRuleCount: f.createdMaxRules}
		f.groups[id] = group
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"firewall_group": group})
		return

	case r.Method == http.MethodPatch && strings.HasPrefix(r.URL.Path, "/instances/"):
		instanceID := strings.TrimPrefix(r.URL.Path, "/instances/")
		var payload struct {
			FirewallGroupID string `json:"firewall_group_id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		f.attachments[instanceID] = payload.FirewallGroupID
		w.WriteHeader(http.StatusNoContent)
		return

	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/instances/"):
		f.deletedInstances = append(f.deletedInstances, strings.TrimPrefix(r.URL.Path, "/instances/"))
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if strings.HasPrefix(r.URL.Path, "/firewalls/") {
		tail := strings.TrimPrefix(r.URL.Path, "/firewalls/")
		if strings.HasSuffix(tail, "/rules") {
			id := strings.TrimSuffix(tail, "/rules")
			switch r.Method {
			case http.MethodGet:
				_ = json.NewEncoder(w).Encode(map[string]any{"firewall_rules": f.rules[id]})
				return
			case http.MethodPost:
				var rule vultrFirewallRule
				_ = json.NewDecoder(r.Body).Decode(&rule)
				for _, existing := range f.rules[id] {
					if firewallRuleKey(existing) == firewallRuleKey(rule) {
						w.WriteHeader(http.StatusConflict)
						_, _ = w.Write([]byte(`{"error":{"message":"duplicate rule"}}`))
						return
					}
				}
				f.ruleCreateCalls++
				rule.ID = len(f.rules[id]) + 1
				f.rules[id] = append(f.rules[id], rule)
				w.WriteHeader(http.StatusCreated)
				_ = json.NewEncoder(w).Encode(map[string]any{"firewall_rule": rule})
				return
			}
		}

		if r.Method == http.MethodDelete {
			id := tail
			if f.groupDelete404[id] {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":{"message":"not found"}}`))
				return
			}
			if _, ok := f.groups[id]; !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			delete(f.groups, id)
			delete(f.rules, id)
			f.deletedGroups = append(f.deletedGroups, id)
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}

	http.NotFound(w, r)
}

func installFirewallFakeAPI(t *testing.T, fake *firewallFakeAPI) *Provider {
	t.Helper()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})
	return New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
}

func allFirewallTestPorts() deploy.PortAssignment {
	return deploy.PortAssignment{
		SSPort:         31001,
		HysteriaPort:   31002,
		VLESSPort:      31003,
		TrojanPort:     31004,
		VLESSRelayPort: 31005,
	}
}

func seedFirewallTestRecord(t *testing.T, provider *Provider, instanceID string) {
	t.Helper()
	if err := provider.persistNodeRecord(instanceID, nodeRecord{InstanceID: instanceID}); err != nil {
		t.Fatalf("seed %s record: %v", instanceID, err)
	}
}

func TestConfigureInstanceFirewallCreatesDedicatedIdempotentGroups(t *testing.T) {
	fake := newFirewallFakeAPI()
	// Merely mentioning PrivateDeploy is not an ownership marker.
	fake.groups["user-group"] = vultrFirewallGroup{ID: "user-group", Description: "Team PrivateDeploy shared rules", MaxRuleCount: 50}
	provider := installFirewallFakeAPI(t, fake)
	ports := allFirewallTestPorts()
	seedFirewallTestRecord(t, provider, "inst-a")
	seedFirewallTestRecord(t, provider, "inst-b")

	if err := provider.configureInstanceFirewall(context.Background(), "inst-a", ports, "node-a"); err != nil {
		t.Fatalf("configure inst-a: %v", err)
	}
	if err := provider.configureInstanceFirewall(context.Background(), "inst-a", ports, "node-a"); err != nil {
		t.Fatalf("repeat configure inst-a: %v", err)
	}
	if err := provider.configureInstanceFirewall(context.Background(), "inst-b", ports, "node-b"); err != nil {
		t.Fatalf("configure inst-b: %v", err)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.createCalls != 2 {
		t.Fatalf("created groups = %d, want one per instance (2)", fake.createCalls)
	}
	if len(fake.groups) != 3 {
		t.Fatalf("groups = %d, want two dedicated plus untouched user group (3)", len(fake.groups))
	}
	if _, ok := fake.groups["user-group"]; !ok {
		t.Fatal("user-created group was incorrectly adopted or removed")
	}
	groupA := fake.attachments["inst-a"]
	groupB := fake.attachments["inst-b"]
	if groupA == "" || groupB == "" || groupA == groupB {
		t.Fatalf("instances must have different dedicated groups: a=%q b=%q", groupA, groupB)
	}
	wantRules := len(firewallRulesForPorts(ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort, ports.VLESSRelayPort, ""))
	if len(fake.rules[groupA]) != wantRules || len(fake.rules[groupB]) != wantRules {
		t.Fatalf("rules leaked/shared: a=%d b=%d want=%d each", len(fake.rules[groupA]), len(fake.rules[groupB]), wantRules)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load ownership records: %v", err)
	}
	if records["inst-a"].FirewallGroupID != groupA || records["inst-a"].FirewallOwnershipToken == "" {
		t.Fatalf("inst-a ownership was not persisted: %#v", records["inst-a"])
	}
	if records["inst-b"].FirewallGroupID != groupB || records["inst-b"].FirewallOwnershipToken == "" {
		t.Fatalf("inst-b ownership was not persisted: %#v", records["inst-b"])
	}
	if fake.groups[groupA].Description != managedFirewallDescription("inst-a", records["inst-a"].FirewallOwnershipToken) {
		t.Fatalf("group description does not carry the persisted ownership marker: %q", fake.groups[groupA].Description)
	}
}

func TestConfigureInstanceFirewallAtGroupCapDoesNotMutateAnyGroup(t *testing.T) {
	fake := newFirewallFakeAPI()
	for i := 0; i < vultrFirewallGroupCap; i++ {
		id := fmt.Sprintf("user-%d", i)
		description := "user managed"
		if i == 0 {
			description = legacyFirewallDescription
		}
		fake.groups[id] = vultrFirewallGroup{ID: id, Description: description, MaxRuleCount: 50}
	}
	provider := installFirewallFakeAPI(t, fake)
	seedFirewallTestRecord(t, provider, "inst-full")

	err := provider.configureInstanceFirewall(context.Background(), "inst-full", allFirewallTestPorts(), "full")
	if err == nil || !strings.Contains(err.Error(), "cap reached") {
		t.Fatalf("expected actionable cap error, got %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.createCalls != 0 || fake.ruleCreateCalls != 0 || len(fake.attachments) != 0 {
		t.Fatalf("quota failure mutated account: creates=%d rules=%d attachments=%d", fake.createCalls, fake.ruleCreateCalls, len(fake.attachments))
	}
}

func TestConfigureInstanceFirewallReusesCompleteLegacyGroupAtCapReadOnly(t *testing.T) {
	fake := newFirewallFakeAPI()
	ports := allFirewallTestPorts()
	fake.groups["legacy"] = vultrFirewallGroup{ID: "legacy", Description: legacyFirewallDescription, MaxRuleCount: 50}
	fake.rules["legacy"] = firewallRulesForPorts(ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort, ports.VLESSRelayPort, "old-label")
	for i := 1; i < vultrFirewallGroupCap; i++ {
		id := fmt.Sprintf("user-%d", i)
		fake.groups[id] = vultrFirewallGroup{ID: id, Description: "user managed", MaxRuleCount: 50}
	}
	provider := installFirewallFakeAPI(t, fake)
	seedFirewallTestRecord(t, provider, "inst-legacy")

	if err := provider.configureInstanceFirewall(context.Background(), "inst-legacy", ports, "new-label"); err != nil {
		t.Fatalf("legacy compatibility configure: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.attachments["inst-legacy"] != "legacy" {
		t.Fatalf("legacy group was not attached: %#v", fake.attachments)
	}
	if fake.createCalls != 0 || fake.ruleCreateCalls != 0 {
		t.Fatalf("legacy group must be read-only: creates=%d rules=%d", fake.createCalls, fake.ruleCreateCalls)
	}
}

func TestConfigureInstanceFirewallRollsBackNewGroupWhenRuleCapacityIsTooSmall(t *testing.T) {
	fake := newFirewallFakeAPI()
	fake.createdMaxRules = 1
	provider := installFirewallFakeAPI(t, fake)
	seedFirewallTestRecord(t, provider, "inst-small")

	err := provider.configureInstanceFirewall(context.Background(), "inst-small", allFirewallTestPorts(), "small")
	if err == nil || !strings.Contains(err.Error(), "needs") {
		t.Fatalf("expected per-group capacity error, got %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.groups) != 0 || len(fake.deletedGroups) != 1 {
		t.Fatalf("failed create must be rolled back: groups=%d deleted=%v", len(fake.groups), fake.deletedGroups)
	}
	if fake.ruleCreateCalls != 0 {
		t.Fatalf("capacity must be checked before partial writes, added %d rules", fake.ruleCreateCalls)
	}
}

func TestDestroyInstanceDeletesOnlyOwnedFirewallGroups(t *testing.T) {
	fake := newFirewallFakeAPI()
	const (
		instanceID  = "21111111-2222-4333-8444-555555555555"
		deleteToken = "delete-ownership-token"
	)
	fake.groups["owned"] = vultrFirewallGroup{ID: "owned", Description: managedFirewallDescription(instanceID, deleteToken), MaxRuleCount: 50}
	fake.groups["duplicate"] = vultrFirewallGroup{ID: "duplicate", Description: managedFirewallDescription(instanceID, deleteToken), MaxRuleCount: 50}
	fake.groups["other-node"] = vultrFirewallGroup{ID: "other-node", Description: managedFirewallDescription("inst-other", "other-token"), MaxRuleCount: 50}
	fake.groups["legacy"] = vultrFirewallGroup{ID: "legacy", Description: legacyFirewallDescription, MaxRuleCount: 50}
	fake.groups["user"] = vultrFirewallGroup{ID: "user", Description: "My PrivateDeploy rules", MaxRuleCount: 50}
	fake.groups["spoof"] = vultrFirewallGroup{ID: "spoof", Description: managedFirewallDescription(instanceID, "wrong-token"), MaxRuleCount: 50}
	provider := installFirewallFakeAPI(t, fake)
	if err := provider.persistNodeRecord(instanceID, nodeRecord{InstanceID: instanceID, FirewallGroupID: "owned", FirewallOwnershipToken: deleteToken}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	if err := provider.DestroyInstance(context.Background(), instanceID); err != nil {
		t.Fatalf("DestroyInstance: %v", err)
	}
	fake.mu.Lock()
	if _, ok := fake.groups["owned"]; ok {
		t.Error("owned group was not deleted")
	}
	if _, ok := fake.groups["duplicate"]; ok {
		t.Error("duplicate owned group was not deleted")
	}
	for _, id := range []string{"other-node", "legacy", "user", "spoof"} {
		if _, ok := fake.groups[id]; !ok {
			t.Errorf("unowned group %q was incorrectly deleted", id)
		}
	}
	fake.mu.Unlock()
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records[instanceID]; ok {
		t.Fatal("local record was not removed")
	}
}

func TestDestroyInstanceTreatsOwnedFirewall404AsAlreadyGone(t *testing.T) {
	fake := newFirewallFakeAPI()
	const (
		instanceID  = "31111111-2222-4333-8444-555555555555"
		deleteToken = "delete-ownership-token"
	)
	fake.groups["gone"] = vultrFirewallGroup{ID: "gone", Description: managedFirewallDescription(instanceID, deleteToken), MaxRuleCount: 50}
	fake.groupDelete404["gone"] = true
	provider := installFirewallFakeAPI(t, fake)
	if err := provider.persistNodeRecord(instanceID, nodeRecord{InstanceID: instanceID, FirewallGroupID: "gone", FirewallOwnershipToken: deleteToken}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	if err := provider.DestroyInstance(context.Background(), instanceID); err != nil {
		t.Fatalf("firewall 404 must be idempotent success: %v", err)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records[instanceID]; ok {
		t.Fatal("local record was not removed after firewall 404")
	}
}

func TestDestroyInstanceCleanupFailureKeepsHiddenRetryRecord(t *testing.T) {
	fake := newFirewallFakeAPI()
	const (
		instanceID = "41111111-2222-4333-8444-555555555555"
		token      = "destroy-retry-token"
	)
	fake.groups["owned"] = vultrFirewallGroup{
		ID:           "owned",
		Description:  managedFirewallDescription(instanceID, token),
		MaxRuleCount: 50,
	}
	fake.firewallListFailures = 1
	provider := installFirewallFakeAPI(t, fake)
	if err := provider.persistNodeRecord(instanceID, nodeRecord{
		InstanceID:             instanceID,
		FirewallGroupID:        "owned",
		FirewallOwnershipToken: token,
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	err := provider.DestroyInstance(context.Background(), instanceID)
	if err == nil || !strings.Contains(err.Error(), "cleanup failed") {
		t.Fatalf("expected cleanup failure after instance deletion, got %v", err)
	}
	records, loadErr := provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatalf("load records: %v", loadErr)
	}
	record, ok := records[instanceID]
	if !ok || !record.FirewallCleanupPending || record.FirewallOwnershipToken != token {
		t.Fatalf("destroy did not preserve hidden cleanup ownership: %#v", record)
	}
	if visible := recordsToInstances(records); len(visible) != 0 {
		t.Fatalf("destroy cleanup tombstone was visible: %#v", visible)
	}

	if _, listErr := provider.ListInstances(context.Background()); listErr != nil {
		t.Fatalf("ListInstances retry: %v", listErr)
	}
	records, loadErr = provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatalf("load records after retry: %v", loadErr)
	}
	if _, ok := records[instanceID]; ok {
		t.Fatal("successful refresh cleanup did not prune retry tombstone")
	}
}

func TestConfigureInstanceFirewallConcurrentCallsCreateOneGroup(t *testing.T) {
	fake := newFirewallFakeAPI()
	provider := installFirewallFakeAPI(t, fake)
	// Simulate a registry reload leaving two Provider objects alive. The lock
	// must cover the Vultr account operation, not only one Go object.
	providerAfterReload := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	ports := allFirewallTestPorts()
	seedFirewallTestRecord(t, provider, "inst-race")

	const callers = 12
	errs := make(chan error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func(call int) {
			defer wg.Done()
			selectedProvider := provider
			if call%2 == 1 {
				selectedProvider = providerAfterReload
			}
			errs <- selectedProvider.configureInstanceFirewall(context.Background(), "inst-race", ports, "race")
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent configure failed: %v", err)
		}
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.createCalls != 1 || len(fake.groups) != 1 {
		t.Fatalf("concurrent calls created duplicates: calls=%d groups=%d", fake.createCalls, len(fake.groups))
	}
	groupID := fake.attachments["inst-race"]
	wantRules := len(firewallRulesForPorts(ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort, ports.VLESSRelayPort, ""))
	if len(fake.rules[groupID]) != wantRules || fake.ruleCreateCalls != wantRules {
		t.Fatalf("concurrent rule reconciliation duplicated rules: stored=%d posts=%d want=%d", len(fake.rules[groupID]), fake.ruleCreateCalls, wantRules)
	}
}

func TestPersistDeploymentWarningPreservesFirewallOwnership(t *testing.T) {
	fake := newFirewallFakeAPI()
	provider := installFirewallFakeAPI(t, fake)
	want := nodeRecord{
		InstanceID:             "inst-warning",
		FirewallGroupID:        "fw-owned",
		FirewallOwnershipToken: "owned-token",
	}
	if err := provider.persistNodeRecord(want.InstanceID, want); err != nil {
		t.Fatalf("seed record: %v", err)
	}
	got, err := provider.persistDeploymentWarning(want.InstanceID, "still starting")
	if err != nil {
		t.Fatalf("persist warning: %v", err)
	}
	if got.FirewallGroupID != want.FirewallGroupID || got.FirewallOwnershipToken != want.FirewallOwnershipToken {
		t.Fatalf("warning update erased ownership: %#v", got)
	}
}

func TestListInstancesRetriesMissingInstanceFirewallCleanupBeforePruning(t *testing.T) {
	fake := newFirewallFakeAPI()
	const token = "cleanup-retry-token"
	fake.groups["owned"] = vultrFirewallGroup{
		ID:           "owned",
		Description:  managedFirewallDescription("inst-missing", token),
		MaxRuleCount: 50,
	}
	fake.firewallListFailures = 1
	provider := installFirewallFakeAPI(t, fake)
	if err := provider.persistNodeRecord("inst-missing", nodeRecord{
		InstanceID:             "inst-missing",
		FirewallGroupID:        "owned",
		FirewallOwnershipToken: token,
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("first ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("cleanup tombstone must stay hidden, got %#v", instances)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load preserved records: %v", err)
	}
	if _, ok := records["inst-missing"]; !ok {
		t.Fatal("cleanup failure erased the only ownership token")
	}
	if !records["inst-missing"].FirewallCleanupPending {
		t.Fatal("failed cleanup record was not marked as a hidden tombstone")
	}

	// Even an offline fallback must not surface the cleanup tombstone as a
	// usable node while it waits for the next successful provider refresh.
	fake.mu.Lock()
	fake.instanceListFailures = 1
	fake.mu.Unlock()
	instances, err = provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("offline fallback ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("offline fallback exposed cleanup tombstone: %#v", instances)
	}

	instances, err = provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("second ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("missing instance unexpectedly became visible: %#v", instances)
	}
	records, err = provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load pruned records: %v", err)
	}
	if _, ok := records["inst-missing"]; ok {
		t.Fatal("record was not pruned after firewall cleanup succeeded")
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if _, ok := fake.groups["owned"]; ok {
		t.Fatal("owned firewall group was not reclaimed on retry")
	}
}

func TestListInstancesOmittedLiveInstanceDoesNotDeleteFirewall(t *testing.T) {
	fake := newFirewallFakeAPI()
	const token = "list-omission-token"
	fake.groups["owned"] = vultrFirewallGroup{
		ID:           "owned",
		Description:  managedFirewallDescription("inst-omitted", token),
		MaxRuleCount: 50,
	}
	fake.liveInstanceLookups["inst-omitted"] = true
	provider := installFirewallFakeAPI(t, fake)
	if err := provider.persistNodeRecord("inst-omitted", nodeRecord{
		InstanceID:             "inst-omitted",
		FirewallGroupID:        "owned",
		FirewallOwnershipToken: token,
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("collection snapshot was empty, got %#v", instances)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if record, ok := records["inst-omitted"]; !ok || record.FirewallCleanupPending {
		t.Fatalf("authoritatively live omitted instance was not preserved: %#v", record)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if _, ok := fake.groups["owned"]; !ok {
		t.Fatal("list omission deleted a live instance's firewall")
	}
	if len(fake.deletedGroups) != 0 {
		t.Fatalf("unexpected firewall deletes: %v", fake.deletedGroups)
	}
}

func TestListInstancesDoesNotPruneRecordCreatedDuringAPIFetch(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	requestStarted := make(chan struct{})
	releaseResponse := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/instances" {
			close(requestStarted)
			<-releaseResponse
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"instances":[]}`))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(server.Close)
	originalClient := vultrHTTPClient
	originalBaseURL := vultrAPIBaseURL
	vultrHTTPClient = server.Client()
	vultrAPIBaseURL = server.URL
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})

	type listResult struct {
		instances []cloud.Instance
		err       error
	}
	result := make(chan listResult, 1)
	go func() {
		instances, err := provider.ListInstances(context.Background())
		result <- listResult{instances: instances, err: err}
	}()
	<-requestStarted
	if err := provider.persistNodeRecord("inst-concurrent", nodeRecord{InstanceID: "inst-concurrent", Label: "new create"}); err != nil {
		close(releaseResponse)
		t.Fatalf("persist concurrent create: %v", err)
	}
	close(releaseResponse)
	got := <-result
	if got.err != nil {
		t.Fatalf("ListInstances: %v", got.err)
	}
	if len(got.instances) != 0 {
		t.Fatalf("API snapshot was empty, got %#v", got.instances)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records["inst-concurrent"]; !ok {
		t.Fatal("stale API snapshot pruned a concurrently-created record")
	}
}

func TestListInstancesDefersPruneForActiveCreateAlreadyInSnapshot(t *testing.T) {
	fake := newFirewallFakeAPI()
	provider := installFirewallFakeAPI(t, fake)
	seedFirewallTestRecord(t, provider, "inst-active-create")
	provider.beginInstanceCreate("inst-active-create")
	defer provider.endInstanceCreate("inst-active-create")

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("in-flight record must remain hidden until API sees it: %#v", instances)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records["inst-active-create"]; !ok {
		t.Fatal("active Create record was pruned before Vultr inventory caught up")
	}
}

func TestClearNodeRecordCredentialsClearsFirewallIdentity(t *testing.T) {
	record := nodeRecord{
		InstanceID:             "inst-new",
		FirewallGroupID:        "fw-old",
		FirewallOwnershipToken: "old-token",
		FirewallCleanupPending: true,
		InstanceRecord: cloud.InstanceRecord{
			SSPort:     32001,
			SSPassword: "secret",
		},
	}
	if !clearNodeRecordCredentials(&record) {
		t.Fatal("expected replacement credentials to change")
	}
	if record.FirewallGroupID != "" || record.FirewallOwnershipToken != "" || record.FirewallCleanupPending {
		t.Fatalf("replacement inherited old firewall identity: %#v", record)
	}
}
