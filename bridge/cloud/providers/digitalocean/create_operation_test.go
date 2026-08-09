package digitalocean

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"privatedeploy/bridge/cloud"
)

type doCreateRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn doCreateRoundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

func doTestResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestCreateInstanceAmbiguousResponsesReconcileTagWithoutSecondDropletPost(t *testing.T) {
	for _, mode := range []string{"transport", "server-500", "missing-id"} {
		t.Run(mode, func(t *testing.T) {
			basePath := t.TempDir()
			t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
			t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
			provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
			originalBaseURL := baseURL
			baseURL = "https://digitalocean.invalid/v2"
			t.Cleanup(func() { baseURL = originalBaseURL })

			var mu sync.Mutex
			dropletPosts := 0
			markerQueries := 0
			firewallCreates := 0
			firewallAttachments := 0
			operationTag := ""
			journalPath := ""
			provider.client = &http.Client{Transport: doCreateRoundTripFunc(func(req *http.Request) (*http.Response, error) {
				switch {
				case req.Method == http.MethodGet && req.URL.Path == "/v2/account/keys":
					return doTestResponse(http.StatusOK, `{"ssh_keys":[]}`), nil
				case req.Method == http.MethodPost && req.URL.Path == "/v2/account/keys":
					var keyRequest struct {
						Name      string `json:"name"`
						PublicKey string `json:"public_key"`
					}
					if err := json.NewDecoder(req.Body).Decode(&keyRequest); err != nil {
						t.Fatalf("decode managed key request: %v", err)
					}
					body, _ := json.Marshal(map[string]any{"ssh_key": doAccountKey{
						ID: 7319, Name: keyRequest.Name, PublicKey: keyRequest.PublicKey,
					}})
					return doTestResponse(http.StatusCreated, string(body)), nil
				case req.Method == http.MethodPost && req.URL.Path == "/v2/droplets":
					journal, err := cloud.ReadCreateOperation(journalPath)
					if err != nil {
						t.Fatalf("read journal at POST boundary: %v", err)
					}
					if journal.State != cloud.CreateOperationSubmitted || len(journal.ProviderData) == 0 {
						t.Fatalf("journal at POST boundary = %#v", journal)
					}
					var prepared digitalOceanCreateOperationData
					if _, err := cloud.LoadCreateOperationProviderData(journalPath, &prepared); err != nil {
						t.Fatalf("load prepared create data: %v", err)
					}
					if prepared.Record.ManagedSSHKeyFingerprint == "" {
						t.Fatal("managed SSH key fingerprint was not encrypted into the create journal")
					}
					var payload struct {
						Tags    []string `json:"tags"`
						SSHKeys []int    `json:"ssh_keys"`
					}
					if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
						t.Fatalf("decode create body: %v", err)
					}
					if len(payload.Tags) != 1 {
						t.Fatalf("create tags = %#v", payload.Tags)
					}
					if len(payload.SSHKeys) == 0 || payload.SSHKeys[0] != 7319 {
						t.Fatalf("managed SSH key attachment = %#v", payload.SSHKeys)
					}
					mu.Lock()
					dropletPosts++
					operationTag = payload.Tags[0]
					mu.Unlock()
					switch mode {
					case "transport":
						return nil, errors.New("connection reset after submit")
					case "server-500":
						return doTestResponse(http.StatusInternalServerError, `{"message":"unknown outcome"}`), nil
					default:
						return doTestResponse(http.StatusAccepted, `{"droplet":{"id":0}}`), nil
					}
				case req.Method == http.MethodGet && req.URL.Path == "/v2/droplets":
					mu.Lock()
					markerQueries++
					tag := operationTag
					mu.Unlock()
					if got := req.URL.Query().Get("tag_name"); got != tag || got == "" {
						t.Fatalf("tag query = %q, want %q", got, tag)
					}
					body, _ := json.Marshal(map[string]any{"droplets": []map[string]any{{
						"id":         44001,
						"name":       "ambiguous-node",
						"status":     "new",
						"created_at": "2026-08-09T01:02:03Z",
						"tags":       []string{tag},
						"region":     map[string]string{"slug": "sgp1"},
						"size":       map[string]string{"slug": "s-1vcpu-1gb"},
						"networks": map[string]any{"v4": []map[string]string{{
							"ip_address": "203.0.113.44", "type": "public",
						}}},
					}}})
					return doTestResponse(http.StatusOK, string(body)), nil
				case req.Method == http.MethodGet && req.URL.Path == "/v2/firewalls":
					records, err := provider.loadNodeRecords()
					if err != nil {
						return nil, err
					}
					token := records["cloud-do-44001"].FirewallOwnershipToken
					if token == "" {
						return nil, errors.New("firewall ownership token was not persisted before lookup")
					}
					body, _ := json.Marshal(map[string]any{"firewalls": []map[string]any{{
						"id": "fw-recovered", "name": managedFirewallName("cloud-do-44001", token),
					}}})
					return doTestResponse(http.StatusOK, string(body)), nil
				case req.Method == http.MethodPost && req.URL.Path == "/v2/firewalls":
					mu.Lock()
					firewallCreates++
					mu.Unlock()
					return doTestResponse(http.StatusCreated, `{"firewall":{"id":"fw-unexpected"}}`), nil
				case req.Method == http.MethodPost && req.URL.Path == "/v2/firewalls/fw-recovered/droplets":
					mu.Lock()
					firewallAttachments++
					mu.Unlock()
					return doTestResponse(http.StatusNoContent, ``), nil
				default:
					return doTestResponse(http.StatusNotFound, `{}`), nil
				}
			})}

			opts := cloud.CreateInstanceOptions{
				OperationID: "ambiguous-" + mode,
				Label:       "ambiguous-node",
				Region:      "sgp1",
				Plan:        "s-1vcpu-1gb",
			}
			journalPath = cloud.CreateOperationJournalPath(basePath, provider.Name(), opts.OperationID)
			if _, created, err := cloud.PrepareCreateOperation(journalPath, provider.Name(), opts); err != nil || !created {
				t.Fatalf("PrepareCreateOperation created=%v err=%v", created, err)
			}
			opts.OperationJournalPath = journalPath
			instance, err := provider.CreateInstance(context.Background(), &opts)
			if instance != nil || !errors.Is(err, cloud.ErrCreateOutcomePending) {
				t.Fatalf("CreateInstance(%s) instance=%#v err=%v, want ambiguous outcome", mode, instance, err)
			}
			instance, err = provider.ReconcileCreateOperation(context.Background(), &opts)
			if err != nil {
				t.Fatalf("ReconcileCreateOperation(%s): %v", mode, err)
			}
			if instance == nil || instance.ID != "cloud-do-44001" || instance.SSPassword == "" || instance.VLESSUUID == "" {
				t.Fatalf("recovered instance = %#v", instance)
			}
			finalized, err := provider.FinalizeReconciledCreate(context.Background(), &opts, instance)
			if err != nil {
				t.Fatalf("FinalizeReconciledCreate(%s): %v", mode, err)
			}
			if finalized == nil || finalized.LastDeployWarning == "" {
				t.Fatalf("finalized instance = %#v, want durable readiness warning", finalized)
			}
			// Repeating finalization after another restart may re-attach the same
			// firewall, but it must never allocate another quota-consuming group.
			if _, err := provider.FinalizeReconciledCreate(context.Background(), &opts, finalized); err != nil {
				t.Fatalf("repeat FinalizeReconciledCreate(%s): %v", mode, err)
			}
			if err := cloud.CompleteCreateOperation(journalPath, finalized); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			posts, queries, creates, attachments := dropletPosts, markerQueries, firewallCreates, firewallAttachments
			mu.Unlock()
			if posts != 1 {
				t.Fatalf("droplet POST count = %d, want 1", posts)
			}
			if queries != 1 {
				t.Fatalf("marker query count = %d, want 1", queries)
			}
			if creates != 0 || attachments != 2 {
				t.Fatalf("firewall creates=%d attachments=%d, want no create and two idempotent attaches", creates, attachments)
			}
			records, err := provider.loadNodeRecords()
			if err != nil {
				t.Fatal(err)
			}
			if got := records[instance.ID].SSPassword; got != instance.SSPassword || got == "" {
				t.Fatalf("persisted password = %q, instance password = %q", got, instance.SSPassword)
			}
			if records[instance.ID].FirewallGroupID != "fw-recovered" || records[instance.ID].LastDeployWarning == "" {
				t.Fatalf("persisted finalization record = %#v", records[instance.ID])
			}
			if records[instance.ID].ManagedSSHKeyFingerprint == "" {
				t.Fatal("recovered node lost its attached managed SSH key fingerprint")
			}
			journal, err := cloud.ReadCreateOperation(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			if journal.State != cloud.CreateOperationSucceeded || journal.Instance == nil || journal.Instance.LastDeployWarning == "" {
				t.Fatalf("terminal journal = %#v", journal)
			}
		})
	}
}

func TestReconcileCreateOperationPreparedStateDoesNotQueryOrPost(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", basePath)
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
	opts := cloud.CreateInstanceOptions{OperationID: "do-before-submit", Label: "node", Region: "sgp1", Plan: "small"}
	journalPath := cloud.CreateOperationJournalPath(basePath, provider.Name(), opts.OperationID)
	if _, _, err := cloud.PrepareCreateOperation(journalPath, provider.Name(), opts); err != nil {
		t.Fatal(err)
	}
	if err := cloud.StoreCreateOperationProviderData(journalPath, cloud.CreateOperationPrepared, digitalOceanCreateOperationData{
		Record: nodeRecord{InstanceRecord: cloud.InstanceRecord{SSPassword: "saved"}},
	}); err != nil {
		t.Fatal(err)
	}
	opts.OperationJournalPath = journalPath
	if _, err := provider.ReconcileCreateOperation(context.Background(), &opts); err == nil || !strings.Contains(err.Error(), "before the create submission boundary") {
		t.Fatalf("prepared reconciliation error = %v", err)
	}
}
