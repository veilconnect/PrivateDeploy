package vultr

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"privatedeploy/bridge/cloud"
)

type vultrCreateRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn vultrCreateRoundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

func TestReconcileCreateOperationAfterRestartRestoresCredentialsWithoutPost(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	opts := cloud.CreateInstanceOptions{
		OperationID: "vultr-restart",
		Label:       "recovered-vultr",
		Region:      "nrt",
		Plan:        "vc2-1c-1gb",
	}
	journalPath := cloud.CreateOperationJournalPath(basePath, provider.Name(), opts.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(journalPath, provider.Name(), opts); err != nil || !created {
		t.Fatalf("PrepareCreateOperation created=%v err=%v", created, err)
	}
	prepared := vultrCreateOperationData{Record: nodeRecord{
		Label:  opts.Label,
		Region: opts.Region,
		InstanceRecord: cloud.InstanceRecord{
			Plan:           opts.Plan,
			OSID:           477,
			Port:           24001,
			Password:       "ss-secret",
			SSPort:         24001,
			SSPassword:     "ss-secret",
			VLESSPort:      24002,
			VLESSUUID:      "11111111-2222-4333-8444-555555555555",
			TrojanPort:     24003,
			TrojanPassword: "trojan-secret",
		},
	}, PlanRAM: 1024}
	if err := cloud.StoreCreateOperationProviderData(journalPath, cloud.CreateOperationPrepared, prepared); err != nil {
		t.Fatal(err)
	}
	if err := cloud.MarkCreateOperationSubmitted(journalPath); err != nil {
		t.Fatal(err)
	}
	opts.OperationJournalPath = journalPath
	wantTag := cloud.CreateOperationTag(provider.Name(), opts.OperationID)

	var posts atomic.Int32
	var gets atomic.Int32
	originalClient, originalBaseURL := vultrHTTPClient, vultrAPIBaseURL
	vultrAPIBaseURL = "https://vultr.invalid/v2"
	vultrHTTPClient = &http.Client{Transport: vultrCreateRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodPost {
			posts.Add(1)
		}
		if req.Method != http.MethodGet || req.URL.Path != "/v2/instances" {
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
		}
		gets.Add(1)
		if got := req.URL.Query().Get("tag"); got != wantTag {
			t.Fatalf("tag query = %q, want %q", got, wantTag)
		}
		body, _ := json.Marshal(map[string]any{"instances": []map[string]any{{
			"id":         "vultr-tagged-1",
			"label":      opts.Label,
			"status":     "active",
			"region":     opts.Region,
			"plan":       opts.Plan,
			"main_ip":    "203.0.113.77",
			"created_at": "2026-08-09T02:03:04Z",
			"tags":       []string{wantTag},
		}}})
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(string(body))),
		}, nil
	})}
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})

	instance, err := provider.ReconcileCreateOperation(context.Background(), &opts)
	if err != nil {
		t.Fatal(err)
	}
	if instance == nil || instance.ID != "vultr-tagged-1" || instance.SSPassword != "ss-secret" || instance.VLESSUUID == "" {
		t.Fatalf("recovered instance = %#v", instance)
	}
	if posts.Load() != 0 {
		t.Fatalf("reconciliation issued %d POST requests", posts.Load())
	}
	if gets.Load() != 1 {
		t.Fatalf("marker GET count = %d, want 1", gets.Load())
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatal(err)
	}
	if got := records[instance.ID].SSPassword; got != "ss-secret" {
		t.Fatalf("persisted password = %q", got)
	}
}

func TestReconcileCreateOperationPreparedStateDoesNotQueryOrPost(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	opts := cloud.CreateInstanceOptions{OperationID: "before-submit", Label: "node", Region: "nrt", Plan: "small"}
	journalPath := cloud.CreateOperationJournalPath(basePath, provider.Name(), opts.OperationID)
	if _, _, err := cloud.PrepareCreateOperation(journalPath, provider.Name(), opts); err != nil {
		t.Fatal(err)
	}
	if err := cloud.StoreCreateOperationProviderData(journalPath, cloud.CreateOperationPrepared, vultrCreateOperationData{
		Record: nodeRecord{InstanceRecord: cloud.InstanceRecord{SSPassword: "saved"}},
	}); err != nil {
		t.Fatal(err)
	}
	opts.OperationJournalPath = journalPath
	if _, err := provider.ReconcileCreateOperation(context.Background(), &opts); err == nil || !strings.Contains(err.Error(), "before the create submission boundary") {
		t.Fatalf("prepared reconciliation error = %v", err)
	}
}

func TestCleanInvalidNodesRetainsFirewallTombstoneWhenCleanupFails(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	const (
		instanceID = "invalid-owned-node"
		token      = "0123456789abcdef01234567"
	)
	if err := provider.persistNodeRecord(instanceID, nodeRecord{
		InstanceID:             instanceID,
		Label:                  "invalid",
		FirewallGroupID:        "fw-owned",
		FirewallOwnershipToken: token,
	}); err != nil {
		t.Fatal(err)
	}

	originalClient, originalBaseURL := vultrHTTPClient, vultrAPIBaseURL
	vultrAPIBaseURL = "https://vultr.invalid/v2"
	vultrHTTPClient = &http.Client{Transport: vultrCreateRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch {
		case req.Method == http.MethodGet && req.URL.Path == "/v2/instances/"+instanceID:
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{"error":{"message":"missing"}}`))}, nil
		case req.Method == http.MethodGet && req.URL.Path == "/v2/firewalls":
			body, _ := json.Marshal(map[string]any{"firewall_groups": []map[string]any{{
				"id": "fw-owned", "description": managedFirewallDescription(instanceID, token),
			}}})
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
		case req.Method == http.MethodDelete && req.URL.Path == "/v2/firewalls/fw-owned":
			return &http.Response{StatusCode: http.StatusUnprocessableEntity, Body: io.NopCloser(strings.NewReader(`{"error":{"message":"denied"}}`))}, nil
		default:
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
		}
	})}
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})

	removed, err := provider.CleanInvalidNodes(context.Background())
	if err == nil || removed != 0 {
		t.Fatalf("CleanInvalidNodes removed=%d err=%v, want retained tombstone and cleanup error", removed, err)
	}
	records, loadErr := provider.loadNodeRecords()
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	record, ok := records[instanceID]
	if !ok || !record.FirewallCleanupPending || record.FirewallOwnershipToken != token || record.FirewallGroupID != "fw-owned" {
		t.Fatalf("retained cleanup record = %#v, present=%v", record, ok)
	}
}

func TestCleanInvalidNodesDoesNotDeleteCredentialsRecoveredDuringRemoteCheck(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	const instanceID = "credentials-recovered-concurrently"
	if err := provider.persistNodeRecord(instanceID, nodeRecord{
		InstanceID: instanceID,
		Label:      "initially-invalid",
	}); err != nil {
		t.Fatal(err)
	}

	remoteCheckStarted := make(chan struct{})
	allowRemoteCheck := make(chan struct{})
	originalClient, originalBaseURL := vultrHTTPClient, vultrAPIBaseURL
	vultrAPIBaseURL = "https://vultr.invalid/v2"
	vultrHTTPClient = &http.Client{Transport: vultrCreateRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodGet && req.URL.Path == "/v2/instances/"+instanceID {
			close(remoteCheckStarted)
			<-allowRemoteCheck
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{"error":{"message":"missing"}}`))}, nil
		}
		return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	t.Cleanup(func() {
		vultrHTTPClient = originalClient
		vultrAPIBaseURL = originalBaseURL
	})

	type cleanResult struct {
		removed int
		err     error
	}
	resultCh := make(chan cleanResult, 1)
	go func() {
		removed, err := provider.CleanInvalidNodes(context.Background())
		resultCh <- cleanResult{removed: removed, err: err}
	}()
	<-remoteCheckStarted
	if err := provider.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		recovered := records[instanceID]
		recovered.Port = 24001
		recovered.Password = "recovered-secret"
		recovered.SSPort = 24001
		recovered.SSPassword = "recovered-secret"
		records[instanceID] = recovered
		return true, nil
	}); err != nil {
		t.Fatal(err)
	}
	close(allowRemoteCheck)
	result := <-resultCh
	if result.err != nil || result.removed != 0 {
		t.Fatalf("CleanInvalidNodes removed=%d err=%v, want recovered record retained", result.removed, result.err)
	}
	records, err := provider.loadNodeRecords()
	if err != nil {
		t.Fatal(err)
	}
	recovered, ok := records[instanceID]
	if !ok || !validateNodeRecord(recovered) || recovered.SSPassword != "recovered-secret" {
		t.Fatalf("concurrently recovered record = %#v, present=%v", recovered, ok)
	}
}
