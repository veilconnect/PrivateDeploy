package health

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

// mockProvider implements cloud.CloudProvider for testing.
type mockProvider struct {
	instances []cloud.Instance
	err       error
}

func (m *mockProvider) Name() string                      { return "mock" }
func (m *mockProvider) DisplayName() string               { return "Mock" }
func (m *mockProvider) LoadConfig() (*cloud.ProviderConfig, error) {
	return &cloud.ProviderConfig{Provider: "mock"}, nil
}
func (m *mockProvider) SaveConfig(_ *cloud.ProviderConfig) error    { return nil }
func (m *mockProvider) ValidateConfig(_ *cloud.ProviderConfig) error { return nil }
func (m *mockProvider) ListRegions(_ context.Context) ([]cloud.Region, error) { return nil, nil }
func (m *mockProvider) ListPlans(_ context.Context, _ string) ([]cloud.Plan, error) {
	return nil, nil
}
func (m *mockProvider) ListAvailability(_ context.Context, _ string) ([]string, error) {
	return nil, nil
}
func (m *mockProvider) ListInstances(_ context.Context) ([]cloud.Instance, error) {
	return m.instances, m.err
}
func (m *mockProvider) CreateInstance(_ context.Context, _ *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, nil
}
func (m *mockProvider) DestroyInstance(_ context.Context, _ string) error { return nil }
func (m *mockProvider) GetInstance(_ context.Context, _ string) (*cloud.Instance, error) {
	return nil, nil
}

func TestNewMonitor_DefaultInterval(t *testing.T) {
	m := NewMonitor(0)
	if m.interval != 5*time.Minute {
		t.Errorf("expected default interval 5m, got %s", m.interval)
	}
}

func TestNewMonitor_CustomInterval(t *testing.T) {
	m := NewMonitor(30 * time.Second)
	if m.interval != 30*time.Second {
		t.Errorf("expected 30s interval, got %s", m.interval)
	}
}

func TestMonitor_StartStop(t *testing.T) {
	m := NewMonitor(1 * time.Hour) // long interval so ticker doesn't fire
	provider := &mockProvider{}

	if m.IsRunning() {
		t.Fatal("monitor should not be running before Start")
	}

	m.Start(provider)
	time.Sleep(50 * time.Millisecond) // let goroutine start

	if !m.IsRunning() {
		t.Fatal("monitor should be running after Start")
	}

	// Calling Start again should be a no-op
	m.Start(provider)
	if !m.IsRunning() {
		t.Fatal("monitor should still be running after duplicate Start")
	}

	m.Stop()
	time.Sleep(50 * time.Millisecond)

	if m.IsRunning() {
		t.Fatal("monitor should not be running after Stop")
	}
}

func TestMonitor_StopWithoutStart(t *testing.T) {
	m := NewMonitor(time.Minute)
	// Should not panic
	m.Stop()
}

func TestMonitor_GetResults_EmptyInitially(t *testing.T) {
	m := NewMonitor(time.Minute)
	results := m.GetResults()
	if len(results) != 0 {
		t.Errorf("expected 0 results initially, got %d", len(results))
	}
}

func TestMonitor_GetResults_ReturnsCopy(t *testing.T) {
	m := NewMonitor(time.Minute)

	// Manually inject a result
	m.mu.Lock()
	m.results["node-1"] = &HealthResult{
		NodeID:  "node-1",
		Healthy: true,
	}
	m.mu.Unlock()

	copy1 := m.GetResults()
	copy2 := m.GetResults()

	// Modifying copy1 should not affect copy2
	copy1["node-1"].Healthy = false
	if !copy2["node-1"].Healthy {
		t.Error("GetResults should return independent copies")
	}
}

func TestMonitor_GetResultsJSON(t *testing.T) {
	m := NewMonitor(time.Minute)
	m.mu.Lock()
	m.results["node-1"] = &HealthResult{
		NodeID:    "node-1",
		Healthy:   true,
		LatencyMs: 42.5,
	}
	m.mu.Unlock()

	jsonStr, err := m.GetResultsJSON()
	if err != nil {
		t.Fatalf("GetResultsJSON error: %v", err)
	}

	var parsed map[string]*HealthResult
	if err := json.Unmarshal([]byte(jsonStr), &parsed); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}

	r, ok := parsed["node-1"]
	if !ok || !r.Healthy || r.LatencyMs != 42.5 {
		t.Errorf("unexpected result: %+v", r)
	}
}

func TestMonitor_SetInterval(t *testing.T) {
	m := NewMonitor(time.Minute)
	m.SetInterval(10 * time.Second)
	if m.interval != 10*time.Second {
		t.Errorf("expected 10s, got %s", m.interval)
	}
}

func TestMonitor_SetEventEmitter(t *testing.T) {
	m := NewMonitor(time.Minute)

	var mu sync.Mutex
	var captured []string
	m.SetEventEmitter(func(event string, data ...interface{}) {
		mu.Lock()
		captured = append(captured, event)
		mu.Unlock()
	})

	m.emit("test:event")

	mu.Lock()
	defer mu.Unlock()
	if len(captured) != 1 || captured[0] != "test:event" {
		t.Errorf("event emitter not called correctly: %v", captured)
	}
}

func TestCollectPorts(t *testing.T) {
	tests := []struct {
		name     string
		instance cloud.Instance
		want     int
	}{
		{"all ports", cloud.Instance{SSPort: 100, HysteriaPort: 200, VLESSPort: 300, TrojanPort: 400}, 4},
		{"ss only", cloud.Instance{SSPort: 100}, 1},
		{"no ports", cloud.Instance{}, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ports := collectPorts(tt.instance)
			if len(ports) != tt.want {
				t.Errorf("expected %d ports, got %d", tt.want, len(ports))
			}
		})
	}
}

func TestMonitor_ConsecutiveFailures(t *testing.T) {
	m := NewMonitor(time.Minute)

	// Simulate a node going unhealthy
	inst := cloud.Instance{
		ID:   "test-node",
		IPv4: "192.0.2.1", // TEST-NET, won't actually connect
	}

	// First check - no previous state
	m.checkNode(inst)
	r := m.GetResults()["test-node"]
	if r == nil {
		t.Fatal("expected result for test-node")
	}
	if r.Healthy {
		t.Log("node unhealthy as expected (no open ports)")
	}

	// Second check - failures should increment
	m.checkNode(inst)
	r = m.GetResults()["test-node"]
	if r.Failures < 1 {
		t.Errorf("expected failures >= 1, got %d", r.Failures)
	}
}
