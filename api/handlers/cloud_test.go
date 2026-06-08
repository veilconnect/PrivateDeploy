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
	return nil, nil
}

func (p *fakeCloudProvider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	return nil, nil
}

func (p *fakeCloudProvider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	return nil, nil
}

func (p *fakeCloudProvider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	return nil, nil
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
	handler := NewCloudHandler(manager)
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
	handler := NewCloudHandler(manager)
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
	handler := NewCloudHandler(manager)
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
	handler := NewCloudHandler(manager)
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
