package digitalocean

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

type digitalOceanFirewallFake struct {
	mu sync.Mutex

	firewalls            map[string]digitalOceanFirewall
	liveDroplets         map[string]bool
	attachments          map[string][]int
	deletedFirewalls     []string
	deletedDroplets      []string
	createCalls          int
	firewallListFailures int
	delete404            map[string]bool
	nextID               int
	listStarted          chan struct{}
	listRelease          chan struct{}
}

func newDigitalOceanFirewallFake() *digitalOceanFirewallFake {
	return &digitalOceanFirewallFake{
		firewalls:    make(map[string]digitalOceanFirewall),
		liveDroplets: make(map[string]bool),
		attachments:  make(map[string][]int),
		delete404:    make(map[string]bool),
	}
}

func (f *digitalOceanFirewallFake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")

	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/droplets":
		if f.listStarted != nil {
			close(f.listStarted)
			f.listStarted = nil
			<-f.listRelease
		}
		_, _ = w.Write([]byte(`{"droplets":[],"links":{"pages":{}}}`))
		return

	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/droplets/"):
		id := strings.TrimPrefix(r.URL.Path, "/droplets/")
		if f.liveDroplets[id] {
			_, _ = w.Write([]byte(`{"droplet":{"id":` + id + `,"name":"live","status":"active"}}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"id":"not_found"}`))
		return

	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/droplets/"):
		id := strings.TrimPrefix(r.URL.Path, "/droplets/")
		f.deletedDroplets = append(f.deletedDroplets, id)
		delete(f.liveDroplets, id)
		w.WriteHeader(http.StatusNoContent)
		return

	case r.Method == http.MethodGet && r.URL.Path == "/firewalls":
		if f.firewallListFailures > 0 {
			f.firewallListFailures--
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"id":"temporary"}`))
			return
		}
		firewalls := make([]digitalOceanFirewall, 0, len(f.firewalls))
		for _, firewall := range f.firewalls {
			firewalls = append(firewalls, firewall)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"firewalls": firewalls})
		return

	case r.Method == http.MethodPost && r.URL.Path == "/firewalls":
		var payload struct {
			Name string `json:"name"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		f.nextID++
		id := fmt.Sprintf("fw-%d", f.nextID)
		firewall := digitalOceanFirewall{ID: id, Name: payload.Name}
		f.firewalls[id] = firewall
		f.createCalls++
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"firewall": firewall})
		return

	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/firewalls/") && strings.HasSuffix(r.URL.Path, "/droplets"):
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/firewalls/"), "/droplets")
		var payload struct {
			DropletIDs []int `json:"droplet_ids"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		f.attachments[id] = append(f.attachments[id], payload.DropletIDs...)
		w.WriteHeader(http.StatusNoContent)
		return

	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/firewalls/"):
		id := strings.TrimPrefix(r.URL.Path, "/firewalls/")
		if f.delete404[id] {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if _, ok := f.firewalls[id]; !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		delete(f.firewalls, id)
		f.deletedFirewalls = append(f.deletedFirewalls, id)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	http.NotFound(w, r)
}

func installDigitalOceanFirewallFake(t *testing.T, fake *digitalOceanFirewallFake) *Provider {
	t.Helper()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	originalBaseURL := baseURL
	baseURL = server.URL
	t.Cleanup(func() { baseURL = originalBaseURL })
	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-key"})
	provider.client = server.Client()
	return provider
}

func digitalOceanTestPorts() deploy.PortAssignment {
	return deploy.PortAssignment{
		SSPort:         33001,
		HysteriaPort:   33002,
		VLESSPort:      33003,
		TrojanPort:     33004,
		VLESSRelayPort: 33005,
	}
}

func TestDigitalOceanFirewallRequestOmitsMissingLegacyPorts(t *testing.T) {
	request := digitalOceanFirewallRequest("legacy-recovered", deploy.PortAssignment{SSPort: 33001})
	inbound, ok := request["inbound_rules"].([]map[string]interface{})
	if !ok {
		t.Fatalf("inbound rules type = %T", request["inbound_rules"])
	}
	if len(inbound) != 3 {
		t.Fatalf("inbound rules = %#v, want SSH plus Shadowsocks TCP/UDP", inbound)
	}
	want := map[string]bool{"tcp:22": true, "tcp:33001": true, "udp:33001": true}
	for _, rule := range inbound {
		key := fmt.Sprintf("%v:%v", rule["protocol"], rule["ports"])
		if !want[key] {
			t.Fatalf("unexpected firewall rule %s in %#v", key, inbound)
		}
		delete(want, key)
	}
	if len(want) != 0 {
		t.Fatalf("missing firewall rules: %#v", want)
	}
}

func seedDigitalOceanRecord(t *testing.T, provider *Provider, instanceID string) {
	t.Helper()
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records[instanceID] = nodeRecord{InstanceRecord: cloud.InstanceRecord{SSPort: 33001, SSPassword: "secret"}}
		return true, nil
	}); err != nil {
		t.Fatalf("seed %s: %v", instanceID, err)
	}
}

func TestConfigureInstanceFirewallIsDedicatedAndConcurrentIdempotent(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	fake.firewalls["legacy"] = digitalOceanFirewall{ID: "legacy", Name: "privatedeploy-23650-23651-23652-23653-23654"}
	fake.firewalls["user"] = digitalOceanFirewall{ID: "user", Name: "team-privatedeploy-shared"}
	provider := installDigitalOceanFirewallFake(t, fake)
	providerAfterReload := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-key"})
	providerAfterReload.client = provider.client
	seedDigitalOceanRecord(t, provider, "cloud-do-101")
	seedDigitalOceanRecord(t, provider, "cloud-do-202")
	ports := digitalOceanTestPorts()

	const callers = 12
	errs := make(chan error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func(call int) {
			defer wg.Done()
			selected := provider
			if call%2 == 1 {
				selected = providerAfterReload
			}
			errs <- selected.configureInstanceFirewall(context.Background(), "cloud-do-101", 101, ports)
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent configure: %v", err)
		}
	}
	if err := provider.configureInstanceFirewall(context.Background(), "cloud-do-202", 202, ports); err != nil {
		t.Fatalf("configure second node: %v", err)
	}

	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.createCalls != 2 {
		t.Fatalf("created firewalls=%d, want one per node", fake.createCalls)
	}
	a := records["cloud-do-101"]
	b := records["cloud-do-202"]
	if a.FirewallGroupID == "" || b.FirewallGroupID == "" || a.FirewallGroupID == b.FirewallGroupID {
		t.Fatalf("nodes did not receive dedicated groups: a=%#v b=%#v", a, b)
	}
	if fake.firewalls[a.FirewallGroupID].Name != managedFirewallName("cloud-do-101", a.FirewallOwnershipToken) {
		t.Fatalf("ownership name mismatch: %#v", fake.firewalls[a.FirewallGroupID])
	}
	for _, id := range []string{"legacy", "user"} {
		if _, ok := fake.firewalls[id]; !ok {
			t.Fatalf("legacy/user firewall %s was modified", id)
		}
	}
}

func TestDestroyInstanceDeletesOnlyVerifiedOwnedFirewall(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	const token = "destroy-token"
	fake.liveDroplets["101"] = true
	fake.firewalls["owned"] = digitalOceanFirewall{ID: "owned", Name: managedFirewallName("cloud-do-101", token)}
	fake.firewalls["duplicate"] = digitalOceanFirewall{ID: "duplicate", Name: managedFirewallName("cloud-do-101", token)}
	fake.firewalls["spoof"] = digitalOceanFirewall{ID: "spoof", Name: managedFirewallName("cloud-do-101", "wrong-token")}
	fake.firewalls["legacy"] = digitalOceanFirewall{ID: "legacy", Name: "privatedeploy-23650-23651-23652-23653-23654"}
	fake.firewalls["user"] = digitalOceanFirewall{ID: "user", Name: "team firewall"}
	provider := installDigitalOceanFirewallFake(t, fake)
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records["cloud-do-101"] = nodeRecord{FirewallGroupID: "owned", FirewallOwnershipToken: token}
		return true, nil
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	if err := provider.DestroyInstance(context.Background(), "cloud-do-101"); err != nil {
		t.Fatalf("DestroyInstance: %v", err)
	}
	fake.mu.Lock()
	for _, id := range []string{"owned", "duplicate"} {
		if _, ok := fake.firewalls[id]; ok {
			fake.mu.Unlock()
			t.Fatalf("owned firewall %s was not deleted", id)
		}
	}
	for _, id := range []string{"spoof", "legacy", "user"} {
		if _, ok := fake.firewalls[id]; !ok {
			fake.mu.Unlock()
			t.Fatalf("unowned firewall %s was incorrectly deleted", id)
		}
	}
	fake.mu.Unlock()
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records["cloud-do-101"]; ok {
		t.Fatal("local record was not deleted")
	}
}

func TestDestroyLegacyFixedPortFirewallIsNeverDeleted(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	fake.firewalls["legacy"] = digitalOceanFirewall{ID: "legacy", Name: "privatedeploy-23650-23651-23652-23653-23654"}
	provider := installDigitalOceanFirewallFake(t, fake)
	seedDigitalOceanRecord(t, provider, "cloud-do-303")
	if err := provider.DestroyInstance(context.Background(), "cloud-do-303"); err != nil {
		t.Fatalf("DestroyInstance legacy: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if _, ok := fake.firewalls["legacy"]; !ok {
		t.Fatal("legacy fixed-port firewall was deleted without ownership proof")
	}
}

func TestDestroyCleanupFailureKeepsHiddenRetryRecord(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	const token = "destroy-retry-token"
	fake.firewalls["owned"] = digitalOceanFirewall{ID: "owned", Name: managedFirewallName("cloud-do-707", token)}
	fake.firewallListFailures = 1
	provider := installDigitalOceanFirewallFake(t, fake)
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records["cloud-do-707"] = nodeRecord{FirewallGroupID: "owned", FirewallOwnershipToken: token}
		return true, nil
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	err := provider.DestroyInstance(context.Background(), "cloud-do-707")
	if err == nil || !strings.Contains(err.Error(), "cleanup failed") {
		t.Fatalf("expected cleanup failure, got %v", err)
	}
	records, loadErr := provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatalf("load records: %v", loadErr)
	}
	if record := records["cloud-do-707"]; !record.FirewallCleanupPending || record.FirewallOwnershipToken != token {
		t.Fatalf("destroy did not preserve hidden cleanup record: %#v", record)
	}
	if _, listErr := provider.ListInstances(context.Background()); listErr != nil {
		t.Fatalf("ListInstances cleanup retry: %v", listErr)
	}
	records, loadErr = provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatalf("load records after retry: %v", loadErr)
	}
	if _, ok := records["cloud-do-707"]; ok {
		t.Fatal("successful retry did not prune cleanup tombstone")
	}
}

func TestListInstancesCleanupFailurePreservesHiddenRecordAndRetries(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	const token = "retry-token"
	fake.firewalls["owned"] = digitalOceanFirewall{ID: "owned", Name: managedFirewallName("cloud-do-404", token)}
	fake.firewallListFailures = 1
	provider := installDigitalOceanFirewallFake(t, fake)
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records["cloud-do-404"] = nodeRecord{FirewallGroupID: "owned", FirewallOwnershipToken: token}
		return true, nil
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	instances, err := provider.ListInstances(context.Background())
	if err != nil {
		t.Fatalf("first ListInstances: %v", err)
	}
	if len(instances) != 0 {
		t.Fatalf("cleanup tombstone became visible: %#v", instances)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if record := records["cloud-do-404"]; !record.FirewallCleanupPending || record.FirewallOwnershipToken != token {
		t.Fatalf("cleanup ownership was not preserved: %#v", record)
	}

	if _, err := provider.ListInstances(context.Background()); err != nil {
		t.Fatalf("retry ListInstances: %v", err)
	}
	records, err = provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records after retry: %v", err)
	}
	if _, ok := records["cloud-do-404"]; ok {
		t.Fatal("successful cleanup did not prune tombstone")
	}
}

func TestListInstancesOmittedLiveDropletDoesNotDeleteFirewall(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	const token = "omitted-token"
	fake.liveDroplets["505"] = true
	fake.firewalls["owned"] = digitalOceanFirewall{ID: "owned", Name: managedFirewallName("cloud-do-505", token)}
	provider := installDigitalOceanFirewallFake(t, fake)
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records["cloud-do-505"] = nodeRecord{FirewallGroupID: "owned", FirewallOwnershipToken: token}
		return true, nil
	}); err != nil {
		t.Fatalf("seed record: %v", err)
	}

	if _, err := provider.ListInstances(context.Background()); err != nil {
		t.Fatalf("ListInstances: %v", err)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records["cloud-do-505"]; !ok {
		t.Fatal("authoritatively live omitted droplet record was pruned")
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if _, ok := fake.firewalls["owned"]; !ok || len(fake.deletedFirewalls) != 0 {
		t.Fatalf("list omission touched live firewall: groups=%v deleted=%v", fake.firewalls, fake.deletedFirewalls)
	}
}

func TestListInstancesDoesNotPruneRecordCreatedDuringFetch(t *testing.T) {
	fake := newDigitalOceanFirewallFake()
	listStarted := make(chan struct{})
	listRelease := make(chan struct{})
	fake.listStarted = listStarted
	fake.listRelease = listRelease
	provider := installDigitalOceanFirewallFake(t, fake)
	type result struct {
		instances []cloud.Instance
		err       error
	}
	resultCh := make(chan result, 1)
	go func() {
		instances, err := provider.ListInstances(context.Background())
		resultCh <- result{instances: instances, err: err}
	}()
	<-listStarted
	seedDigitalOceanRecord(t, provider, "cloud-do-606")
	close(listRelease)
	got := <-resultCh
	if got.err != nil {
		t.Fatalf("ListInstances: %v", got.err)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatalf("load records: %v", err)
	}
	if _, ok := records["cloud-do-606"]; !ok {
		t.Fatal("stale API snapshot pruned concurrent Create record")
	}
}
