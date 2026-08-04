package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func TestReadOnlyTransportRejectsNonGETBeforeNetwork(t *testing.T) {
	called := false
	client := newReadOnlyClient(time.Second, roundTripFunc(func(*http.Request) (*http.Response, error) {
		called = true
		return nil, errors.New("must not be called")
	}))
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, "https://example.invalid/v2/account/keys", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Do(req)
	if err == nil || !strings.Contains(err.Error(), "rejected HTTP method") {
		t.Fatalf("expected fail-closed method rejection, got %v", err)
	}
	if called {
		t.Fatal("non-GET request reached the underlying transport")
	}
}

func TestProviderProbesSendOnlyGET(t *testing.T) {
	var mu sync.Mutex
	methods := make([]string, 0, 6)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		methods = append(methods, r.Method+" "+r.URL.Path)
		mu.Unlock()
		if r.Method != http.MethodGet {
			t.Errorf("fake API observed forbidden HTTP method %q for %s", r.Method, r.URL.Path)
			http.Error(w, "non-GET rejected", http.StatusMethodNotAllowed)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer fake-key" {
			http.Error(w, "missing auth", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v2/regions":
			if r.URL.Query().Get("per_page") == "500" {
				_, _ = w.Write([]byte(`{"regions":[{"id":"ewr"}]}`))
			} else {
				_, _ = w.Write([]byte(`{"regions":[{"slug":"nyc3","available":true}]}`))
			}
		case "/v2/plans":
			_, _ = w.Write([]byte(`{"plans":[{"id":"vc2-1c-1gb","locations":["ewr"]}]}`))
		case "/v2/instances":
			_, _ = w.Write([]byte(`{"instances":[]}`))
		case "/v2/sizes":
			_, _ = w.Write([]byte(`{"sizes":[{"slug":"s-1vcpu-1gb","available":true,"regions":["nyc3"]}]}`))
		case "/v2/droplets":
			_, _ = w.Write([]byte(`{"droplets":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	client := newReadOnlyClient(2*time.Second, nil)
	for _, name := range []string{"vultr", "digitalocean"} {
		rep := (providerProbe{name: name, baseURL: server.URL, apiKey: "fake-key", client: client}).run(2 * time.Second)
		if !rep.LiveAPIOK {
			t.Fatalf("%s probe failed: %#v", name, rep)
		}
		if !rep.Regions.OK || !rep.Plans.OK || !rep.Availability.OK || !rep.Instances.OK {
			t.Fatalf("%s operation failed: %#v", name, rep)
		}
	}

	mu.Lock()
	defer mu.Unlock()
	if len(methods) != 6 {
		t.Fatalf("expected six GET requests, got %d: %v", len(methods), methods)
	}
	for _, methodAndPath := range methods {
		if !strings.HasPrefix(methodAndPath, http.MethodGet+" ") {
			t.Fatalf("fake API observed a non-GET request: %s", methodAndPath)
		}
	}
}
