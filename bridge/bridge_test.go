package bridge

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"privatedeploy/bridge/cloud"
)

type mockLatencyProvider struct{}

func (m *mockLatencyProvider) Name() string { return "mock" }

func (m *mockLatencyProvider) DisplayName() string { return "Mock" }

func (m *mockLatencyProvider) LoadConfig() (*cloud.ProviderConfig, error) {
	return &cloud.ProviderConfig{Provider: "mock"}, nil
}

func (m *mockLatencyProvider) SaveConfig(config *cloud.ProviderConfig) error { return nil }

func (m *mockLatencyProvider) ValidateConfig(config *cloud.ProviderConfig) error { return nil }

func (m *mockLatencyProvider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	return []cloud.Region{{ID: "nrt", City: "Tokyo", Country: "JP", Continent: "Asia"}}, nil
}

func (m *mockLatencyProvider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	return nil, nil
}

func (m *mockLatencyProvider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	return nil, nil
}

func (m *mockLatencyProvider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	return nil, nil
}

func (m *mockLatencyProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, nil
}

func (m *mockLatencyProvider) DestroyInstance(ctx context.Context, instanceID string) error {
	return nil
}

func (m *mockLatencyProvider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	return nil, nil
}

func (m *mockLatencyProvider) TestRegionLatency(ctx context.Context, regionCode string) (*cloud.RegionLatency, error) {
	return &cloud.RegionLatency{Code: regionCode, Name: "Tokyo", Status: "ok", Latency: 12}, nil
}

func (m *mockLatencyProvider) TestAllRegions(ctx context.Context) ([]*cloud.RegionLatency, error) {
	return []*cloud.RegionLatency{{Code: "nrt", Name: "Tokyo", Status: "ok", Latency: 12}}, nil
}

func (m *mockLatencyProvider) GetFastestRegion(ctx context.Context) (*cloud.RegionLatency, error) {
	return &cloud.RegionLatency{Code: "nrt", Name: "Tokyo", Status: "ok", Latency: 12}, nil
}

func newLatencyTestApp(t *testing.T) *App {
	t.Helper()

	registry := cloud.NewRegistry()
	registry.Register("mock", &mockLatencyProvider{})

	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("mock"); err != nil {
		t.Fatalf("SetActiveProvider() error = %v", err)
	}

	return &App{CloudManager: manager}
}

func TestResolveBasePathUsesExecutableDirForPortableLinux(t *testing.T) {
	t.Setenv("HOME", "/home/tester")

	got := resolveBasePath("linux", "/home/tester/PrivateDeploy/privatedeploy")
	want := "/home/tester/PrivateDeploy"

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathUsesUserDataDirForSystemLinuxInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got := resolveBasePath("linux", "/usr/lib/privatedeploy/privatedeploy")
	want := filepath.Join(home, ".local", "share", "PrivateDeploy")

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathKeepsNonLinuxExecutableDir(t *testing.T) {
	got := resolveBasePath("darwin", "/Applications/PrivateDeploy.app/Contents/MacOS/PrivateDeploy")
	want := "/Applications/PrivateDeploy.app/Contents/MacOS"

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathUsesLocalAppDataForWindowsSystemInstall(t *testing.T) {
	localAppData := t.TempDir()
	t.Setenv("LOCALAPPDATA", localAppData)
	t.Setenv("ProgramFiles", `C:/Program Files`)
	t.Setenv("ProgramFiles(x86)", `C:/Program Files (x86)`)
	t.Setenv("ProgramW6432", `C:/Program Files`)

	got := resolveBasePath("windows", `C:/Program Files/PrivateDeploy/PrivateDeploy.exe`)
	want := filepath.Join(localAppData, "PrivateDeploy")

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestResolveBasePathKeepsPortableWindowsExecutableDir(t *testing.T) {
	t.Setenv("LOCALAPPDATA", t.TempDir())
	t.Setenv("ProgramFiles", `C:/Program Files`)
	t.Setenv("ProgramFiles(x86)", `C:/Program Files (x86)`)
	t.Setenv("ProgramW6432", `C:/Program Files`)

	got := resolveBasePath("windows", `D:/Tools/PrivateDeploy/PrivateDeploy.exe`)
	want := `D:/Tools/PrivateDeploy`

	if got != want {
		t.Fatalf("resolveBasePath() = %q, want %q", got, want)
	}
}

func TestTestCloudRegionLatencyUsesCloudLatencyTester(t *testing.T) {
	app := newLatencyTestApp(t)

	result := app.TestCloudRegionLatency("nrt")
	if !result.Flag {
		t.Fatalf("TestCloudRegionLatency() failed: %s", result.Data)
	}

	var latency cloud.RegionLatency
	if err := json.Unmarshal([]byte(result.Data), &latency); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}

	if latency.Code != "nrt" || latency.Status != "ok" {
		t.Fatalf("unexpected latency result: %+v", latency)
	}
}

func TestTestAllCloudRegionsUsesCloudLatencyTester(t *testing.T) {
	app := newLatencyTestApp(t)

	result := app.TestAllCloudRegions()
	if !result.Flag {
		t.Fatalf("TestAllCloudRegions() failed: %s", result.Data)
	}

	var latencies []cloud.RegionLatency
	if err := json.Unmarshal([]byte(result.Data), &latencies); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}

	if len(latencies) != 1 || latencies[0].Code != "nrt" {
		t.Fatalf("unexpected latencies result: %+v", latencies)
	}
}

func TestGetFastestCloudRegionUsesCloudLatencyTester(t *testing.T) {
	app := newLatencyTestApp(t)

	result := app.GetFastestCloudRegion()
	if !result.Flag {
		t.Fatalf("GetFastestCloudRegion() failed: %s", result.Data)
	}

	var latency cloud.RegionLatency
	if err := json.Unmarshal([]byte(result.Data), &latency); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}

	if latency.Code != "nrt" || latency.Status != "ok" {
		t.Fatalf("unexpected fastest region result: %+v", latency)
	}
}

type mockNamedProvider struct {
	name        string
	displayName string
}

func (m *mockNamedProvider) Name() string        { return m.name }
func (m *mockNamedProvider) DisplayName() string { return m.displayName }
func (m *mockNamedProvider) LoadConfig() (*cloud.ProviderConfig, error) {
	return &cloud.ProviderConfig{Provider: m.name}, nil
}
func (m *mockNamedProvider) SaveConfig(config *cloud.ProviderConfig) error           { return nil }
func (m *mockNamedProvider) ValidateConfig(config *cloud.ProviderConfig) error       { return nil }
func (m *mockNamedProvider) ListRegions(ctx context.Context) ([]cloud.Region, error) { return nil, nil }
func (m *mockNamedProvider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	return nil, nil
}
func (m *mockNamedProvider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	return nil, nil
}
func (m *mockNamedProvider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	return nil, nil
}
func (m *mockNamedProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, nil
}
func (m *mockNamedProvider) DestroyInstance(ctx context.Context, instanceID string) error { return nil }
func (m *mockNamedProvider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	return nil, nil
}

func TestListCloudProvidersTypedFiltersExperimentalProviders(t *testing.T) {
	registry := cloud.NewRegistry()
	registry.Register("vultr", &mockNamedProvider{name: "vultr", displayName: "Vultr"})
	registry.Register("oracle", &mockNamedProvider{name: "oracle", displayName: "Oracle Cloud"})

	manager := cloud.NewManager(context.Background(), registry)
	app := &App{CloudManager: manager}

	providers, err := app.ListCloudProvidersTyped()
	if err != nil {
		t.Fatalf("ListCloudProvidersTyped() error = %v", err)
	}

	if len(providers) != 1 || providers[0].Name != "vultr" {
		t.Fatalf("expected only public providers, got %+v", providers)
	}
}

func TestSetCloudProviderTypedRejectsExperimentalProvider(t *testing.T) {
	registry := cloud.NewRegistry()
	registry.Register("oracle", &mockNamedProvider{name: "oracle", displayName: "Oracle Cloud"})

	manager := cloud.NewManager(context.Background(), registry)
	app := &App{CloudManager: manager}

	if _, err := app.SetCloudProviderTyped("oracle"); err == nil {
		t.Fatal("expected experimental provider to be rejected")
	}
}
