package vultr

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestCreateVultrInstanceAddsOperationTag(t *testing.T) {
	tagSeen := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Tags []string `json:"tags"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if len(payload.Tags) > 0 {
			tagSeen <- payload.Tags[0]
		} else {
			tagSeen <- ""
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"instance":{"id":"inst-tagged"}}`))
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
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})
	opts := &cloud.CreateInstanceOptions{
		Label:       "tagged",
		Region:      "ewr",
		Plan:        "vc2-1c-1gb",
		OperationID: "operation-123",
	}
	if _, _, err := provider.createVultrInstance(context.Background(), opts, []int{477}, "#!/bin/sh"); err != nil {
		t.Fatalf("createVultrInstance: %v", err)
	}
	if got, want := <-tagSeen, cloud.CreateOperationTag("vultr", opts.OperationID); got != want {
		t.Fatalf("operation tag=%q, want %q", got, want)
	}
}

func TestCreateVultrInstanceDoesNotPostAgainAfterAcceptedConnectionDrops(t *testing.T) {
	var posts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/instances" {
			http.NotFound(w, r)
			return
		}
		posts.Add(1)
		// Simulate Vultr accepting/processing the request and then losing the
		// HTTP response. The client cannot know whether a billable VM exists.
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			t.Fatal("test server does not support hijacking")
		}
		conn, _, err := hijacker.Hijack()
		if err != nil {
			t.Fatalf("hijack: %v", err)
		}
		_ = conn.Close()
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
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})

	_, _, err := provider.createVultrInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label:  "no-duplicate",
		Region: "ewr",
		Plan:   "vc2-1c-1gb",
	}, []int{477, 1743}, "#!/bin/sh")
	if err == nil {
		t.Fatal("expected ambiguous transport error")
	}
	if !errors.Is(err, cloud.ErrCreateOutcomePending) {
		t.Fatalf("transport ambiguity did not return reconciliation sentinel: %v", err)
	}
	if got := posts.Load(); got != 1 {
		t.Fatalf("POST /instances count=%d, want exactly 1 after ambiguous response", got)
	}
}

func TestCreateVultrInstanceFallsBackOnlyOnExplicitOSIDRejection(t *testing.T) {
	var posts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt := posts.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if attempt == 1 {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"os_id is invalid for this plan"}}`))
			return
		}
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"instance":{"id":"inst-one","label":"fallback"}}`))
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
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})

	payload, osID, err := provider.createVultrInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label:  "fallback",
		Region: "ewr",
		Plan:   "vc2-1c-1gb",
	}, []int{477, 1743}, "#!/bin/sh")
	if err != nil {
		t.Fatalf("explicit OS fallback failed: %v", err)
	}
	if payload.Instance.ID != "inst-one" || osID != 1743 || posts.Load() != 2 {
		t.Fatalf("unexpected fallback result: id=%q os=%d posts=%d", payload.Instance.ID, osID, posts.Load())
	}
}

func TestCreateVultrInstanceDoesNotFallbackOnServerErrorMentioningOSID(t *testing.T) {
	var posts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		posts.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"message":"os_id backend unavailable"}}`))
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
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-key"})

	_, _, err := provider.createVultrInstance(context.Background(), &cloud.CreateInstanceOptions{
		Label:  "server-error",
		Region: "ewr",
		Plan:   "vc2-1c-1gb",
	}, []int{477, 1743}, "#!/bin/sh")
	if err == nil {
		t.Fatal("expected server error")
	}
	if !errors.Is(err, cloud.ErrCreateOutcomePending) {
		t.Fatalf("5xx ambiguity did not return reconciliation sentinel: %v", err)
	}
	if posts.Load() != 1 {
		t.Fatalf("server ambiguity triggered duplicate POSTs: %d", posts.Load())
	}
}
