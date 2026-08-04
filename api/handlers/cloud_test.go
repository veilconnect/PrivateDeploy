package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"privatedeploy/bridge/cloud"

	"github.com/gin-gonic/gin"
)

type fakeCloudProvider struct {
	name        string
	displayName string
	cfg         *cloud.ProviderConfig

	// Optional canned read-endpoint data, used to tell providers apart in
	// explicit-provider tests.
	regions      []cloud.Region
	plans        []cloud.Plan
	instances    []cloud.Instance
	availability []string
}

func (p *fakeCloudProvider) Name() string {
	if p.name != "" {
		return p.name
	}
	return "vultr"
}

func (p *fakeCloudProvider) DisplayName() string {
	if p.displayName != "" {
		return p.displayName
	}
	return "Vultr"
}

func (p *fakeCloudProvider) LoadConfig() (*cloud.ProviderConfig, error) { return p.cfg, nil }

func (p *fakeCloudProvider) SaveConfig(config *cloud.ProviderConfig) error {
	p.cfg = config
	return nil
}

func (p *fakeCloudProvider) ValidateConfig(config *cloud.ProviderConfig) error { return nil }

func (p *fakeCloudProvider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	return p.regions, nil
}

func (p *fakeCloudProvider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	return p.plans, nil
}

func (p *fakeCloudProvider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	return p.availability, nil
}

func (p *fakeCloudProvider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	return p.instances, nil
}

func (p *fakeCloudProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, nil
}

func (p *fakeCloudProvider) DestroyInstance(ctx context.Context, instanceID string) error { return nil }

func (p *fakeCloudProvider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	return nil, nil
}

func TestCloudHandlerGetConfigRedactsAPIKey(t *testing.T) {
	gin.SetMode(gin.TestMode)

	registry := cloud.NewRegistry()
	registry.Register("vultr", &fakeCloudProvider{
		cfg: &cloud.ProviderConfig{
			Provider:      "vultr",
			APIKey:        "secret-token",
			DefaultRegion: "nrt",
			DefaultPlan:   "vc2-1c-1gb",
			Extra: map[string]string{
				"mode": "test",
			},
		},
	})

	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("vultr"); err != nil {
		t.Fatalf("set active provider: %v", err)
	}

	router := gin.New()
	handler := NewCloudHandler(manager, nil, "test-fp-secret")
	router.GET("/cloud/config", handler.GetConfig)

	req := httptest.NewRequest(http.MethodGet, "/cloud/config", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if payload["success"] != true {
		t.Fatalf("expected success response, got %#v", payload)
	}

	data, ok := payload["data"].(map[string]any)
	if !ok {
		t.Fatalf("expected object payload, got %#v", payload["data"])
	}

	if data["hasApiKey"] != true {
		t.Fatalf("expected hasApiKey=true, got %#v", data["hasApiKey"])
	}

	if _, exists := data["apiKey"]; exists {
		t.Fatalf("expected apiKey to be redacted, got %#v", data["apiKey"])
	}

	if data["defaultRegion"] != "nrt" {
		t.Fatalf("expected defaultRegion to be preserved, got %#v", data["defaultRegion"])
	}
}

func TestCloudHandlerGetConfigRedactsSensitiveSSHExtra(t *testing.T) {
	gin.SetMode(gin.TestMode)

	registry := cloud.NewRegistry()
	registry.Register("ssh", &fakeCloudProvider{
		name: "ssh",
		cfg: &cloud.ProviderConfig{
			Provider: "ssh",
			Extra: map[string]string{
				"host":       "203.0.113.10",
				"username":   "root",
				"authMethod": "password",
				"password":   "secret",
				"privateKey": "PRIVATE",
			},
		},
	})

	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("ssh"); err != nil {
		t.Fatalf("set active provider: %v", err)
	}

	router := gin.New()
	handler := NewCloudHandler(manager, nil, "test-fp-secret")
	router.GET("/cloud/config", handler.GetConfig)

	req := httptest.NewRequest(http.MethodGet, "/cloud/config", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	data := payload["data"].(map[string]any)
	extra := data["extra"].(map[string]any)
	if _, exists := extra["password"]; exists {
		t.Fatalf("expected password to be redacted, got %#v", extra["password"])
	}
	if _, exists := extra["privateKey"]; exists {
		t.Fatalf("expected privateKey to be redacted, got %#v", extra["privateKey"])
	}
	if extra["host"] != "203.0.113.10" {
		t.Fatalf("expected host to be preserved, got %#v", extra["host"])
	}
}

func TestCloudHandlerListProvidersFiltersExperimentalProviders(t *testing.T) {
	gin.SetMode(gin.TestMode)

	registry := cloud.NewRegistry()
	registry.Register("vultr", &fakeCloudProvider{name: "vultr", displayName: "Vultr"})
	registry.Register("oracle", &fakeCloudProvider{name: "oracle", displayName: "Oracle Cloud"})

	manager := cloud.NewManager(context.Background(), registry)
	router := gin.New()
	handler := NewCloudHandler(manager, nil, "test-fp-secret")
	router.GET("/cloud/providers", handler.ListProviders)

	req := httptest.NewRequest(http.MethodGet, "/cloud/providers", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	data, ok := payload["data"].(map[string]any)
	if !ok {
		t.Fatalf("expected object payload, got %#v", payload["data"])
	}
	providers, ok := data["providers"].([]any)
	if !ok {
		t.Fatalf("expected providers array, got %#v", data["providers"])
	}
	if len(providers) != 1 {
		t.Fatalf("expected only public providers to be exposed, got %#v", providers)
	}
}

func TestCloudHandlerSetActiveProviderRejectsExperimentalProviders(t *testing.T) {
	gin.SetMode(gin.TestMode)

	registry := cloud.NewRegistry()
	registry.Register("oracle", &fakeCloudProvider{name: "oracle", displayName: "Oracle Cloud"})

	manager := cloud.NewManager(context.Background(), registry)
	router := gin.New()
	handler := NewCloudHandler(manager, nil, "test-fp-secret")
	router.POST("/cloud/provider/active", handler.SetActiveProvider)

	req := httptest.NewRequest(http.MethodPost, "/cloud/provider/active", strings.NewReader(`{"provider":"oracle"}`))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

// newReadEndpointsEnv builds a router over two public providers with
// distinguishable read data: vultr (the active provider) and ssh.
func newReadEndpointsEnv(t *testing.T) (*gin.Engine, *fakeCloudProvider, *fakeCloudProvider) {
	t.Helper()
	gin.SetMode(gin.TestMode)

	vultr := &fakeCloudProvider{
		name:        "vultr",
		displayName: "Vultr",
		cfg: &cloud.ProviderConfig{
			Provider:      "vultr",
			DefaultRegion: "nrt",
			Extra:         map[string]string{},
		},
		regions:      []cloud.Region{{ID: "vultr-region"}},
		plans:        []cloud.Plan{{ID: "vultr-plan"}},
		instances:    []cloud.Instance{{ID: "vultr-instance", Provider: "vultr"}},
		availability: []string{"vultr-plan"},
	}
	ssh := &fakeCloudProvider{
		name:        "ssh",
		displayName: "SSH Server",
		cfg: &cloud.ProviderConfig{
			Provider:      "ssh",
			DefaultRegion: "local",
			Extra:         map[string]string{},
		},
		regions:      []cloud.Region{{ID: "ssh-region"}},
		plans:        []cloud.Plan{{ID: "ssh-plan"}},
		instances:    []cloud.Instance{{ID: "ssh-instance", Provider: "ssh"}},
		availability: []string{"ssh-plan"},
	}

	registry := cloud.NewRegistry()
	registry.Register("vultr", vultr)
	registry.Register("ssh", ssh)

	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("vultr"); err != nil {
		t.Fatalf("set active provider: %v", err)
	}

	handler := NewCloudHandler(manager, nil, "test-fp-secret")
	router := gin.New()
	router.GET("/cloud/config", handler.GetConfig)
	router.POST("/cloud/config", handler.SaveConfig)
	router.GET("/cloud/instances", handler.ListInstances)
	router.GET("/cloud/regions", handler.ListRegions)
	router.GET("/cloud/plans", handler.ListPlans)
	router.GET("/cloud/availability", handler.ListAvailability)
	return router, vultr, ssh
}

func getJSON(t *testing.T, router *gin.Engine, url string) map[string]any {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s: expected 200, got %d: %s", url, rec.Code, rec.Body.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode %s: %v", url, err)
	}
	data, ok := payload["data"].(map[string]any)
	if !ok {
		t.Fatalf("GET %s: expected data object, got %#v", url, payload)
	}
	return data
}

func firstListItemID(t *testing.T, data map[string]any, listKey string) string {
	t.Helper()
	list, ok := data[listKey].([]any)
	if !ok || len(list) == 0 {
		t.Fatalf("expected non-empty %q list, got %#v", listKey, data[listKey])
	}
	item, ok := list[0].(map[string]any)
	if !ok {
		t.Fatalf("expected object items in %q, got %#v", listKey, list[0])
	}
	id, _ := item["id"].(string)
	return id
}

func TestReadEndpointsHonorExplicitProviderQuery(t *testing.T) {
	router, _, _ := newReadEndpointsEnv(t)

	// The explicitly requested provider (ssh) differs from the active one.
	if data := getJSON(t, router, "/cloud/config?provider=ssh"); data["provider"] != "ssh" {
		t.Fatalf("expected ssh config, got %#v", data["provider"])
	}
	if id := firstListItemID(t, getJSON(t, router, "/cloud/regions?provider=ssh"), "regions"); id != "ssh-region" {
		t.Fatalf("expected ssh regions, got %q", id)
	}
	if id := firstListItemID(t, getJSON(t, router, "/cloud/plans?provider=ssh"), "plans"); id != "ssh-plan" {
		t.Fatalf("expected ssh plans, got %q", id)
	}
	if id := firstListItemID(t, getJSON(t, router, "/cloud/instances?provider=ssh"), "instances"); id != "ssh-instance" {
		t.Fatalf("expected ssh instances, got %q", id)
	}
	availability, _ := getJSON(t, router, "/cloud/availability?provider=ssh&region=local")["availability"].([]any)
	if len(availability) != 1 || availability[0] != "ssh-plan" {
		t.Fatalf("expected ssh availability, got %#v", availability)
	}
}

func TestReadEndpointsFallBackToActiveProvider(t *testing.T) {
	router, _, _ := newReadEndpointsEnv(t)

	if data := getJSON(t, router, "/cloud/config"); data["provider"] != "vultr" {
		t.Fatalf("expected active provider (vultr) config, got %#v", data["provider"])
	}
	if id := firstListItemID(t, getJSON(t, router, "/cloud/regions"), "regions"); id != "vultr-region" {
		t.Fatalf("expected active provider regions, got %q", id)
	}
	if id := firstListItemID(t, getJSON(t, router, "/cloud/instances"), "instances"); id != "vultr-instance" {
		t.Fatalf("expected active provider instances, got %q", id)
	}
}

func TestReadEndpointsRejectUnknownExplicitProvider(t *testing.T) {
	router, _, _ := newReadEndpointsEnv(t)

	// Experimental provider name → 400.
	req := httptest.NewRequest(http.MethodGet, "/cloud/regions?provider=oracle", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for experimental provider, got %d: %s", rec.Code, rec.Body.String())
	}

	// Public but unregistered provider name → 404.
	req = httptest.NewRequest(http.MethodGet, "/cloud/regions?provider=digitalocean", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unregistered provider, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestSaveConfigBodyProviderSelectsProvider(t *testing.T) {
	router, vultr, ssh := newReadEndpointsEnv(t)

	body := `{"provider":"ssh","defaultRegion":"remote","extra":{"host":"203.0.113.9"}}`
	req := httptest.NewRequest(http.MethodPost, "/cloud/config", strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if ssh.cfg == nil || ssh.cfg.DefaultRegion != "remote" {
		t.Fatalf("expected the ssh provider to receive the config, got %#v", ssh.cfg)
	}
	if vultr.cfg != nil && vultr.cfg.DefaultRegion == "remote" {
		t.Fatal("active provider must not receive a config addressed to another provider")
	}
}

func TestSaveConfigWithoutProviderFallsBackToActive(t *testing.T) {
	router, vultr, _ := newReadEndpointsEnv(t)

	body := `{"defaultRegion":"fra"}`
	req := httptest.NewRequest(http.MethodPost, "/cloud/config", strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if vultr.cfg == nil || vultr.cfg.DefaultRegion != "fra" {
		t.Fatalf("expected the active provider to receive the config, got %#v", vultr.cfg)
	}
	if vultr.cfg.Provider != "vultr" {
		t.Fatalf("expected the provider field to be filled in, got %q", vultr.cfg.Provider)
	}
}
