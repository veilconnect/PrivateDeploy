package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

type mockLatencyProvider struct{}

type idempotentCreateProvider struct {
	mockLatencyProvider
	calls atomic.Int32
}

type blockingAccountCreateProvider struct {
	idempotentCreateProvider
	entered chan struct{}
	release chan struct{}
}

type publicCreateProvider struct {
	idempotentCreateProvider
}

type panicCreateProvider struct {
	mockLatencyProvider
}

func (p *publicCreateProvider) Name() string        { return "vultr" }
func (p *publicCreateProvider) DisplayName() string { return "Vultr" }

func (p *panicCreateProvider) CreateInstance(context.Context, *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	panic("provider payload contains api-key-super-secret")
}

func (p *panicCreateProvider) ReconcileCreateOperation(context.Context, *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, errors.New("reconciliation found no instance")
}

func (p *blockingAccountCreateProvider) GetAccountStatus(ctx context.Context) (*cloud.AccountStatus, error) {
	close(p.entered)
	select {
	case <-p.release:
		return &cloud.AccountStatus{State: "active", CanDeploy: true}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (p *idempotentCreateProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	p.calls.Add(1)
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(25 * time.Millisecond):
	}
	return &cloud.Instance{ID: "one", Provider: p.Name(), Label: opts.Label}, nil
}

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

func TestCreateCloudInstanceTypedDeduplicatesOperationID(t *testing.T) {
	operationBase := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(operationBase, "secrets"))
	provider := &idempotentCreateProvider{}
	registry := cloud.NewRegistry()
	registry.Register("mock", provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("mock"); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: operationBase}

	var wg sync.WaitGroup
	results := make(chan *cloud.Instance, 2)
	errors := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			instance, err := app.CreateCloudInstanceTyped(cloud.CreateInstanceOptions{
				OperationID: "stable-operation",
				Label:       "node",
			})
			results <- instance
			errors <- err
		}()
	}
	wg.Wait()
	close(results)
	close(errors)

	for err := range errors {
		if err != nil {
			t.Fatalf("CreateCloudInstanceTyped() error = %v", err)
		}
	}
	for instance := range results {
		if instance == nil || instance.ID != "one" {
			t.Fatalf("unexpected instance: %#v", instance)
		}
	}
	if got := provider.calls.Load(); got != 1 {
		t.Fatalf("provider create calls = %d, want 1", got)
	}
}

func TestCreateCloudInstanceTypedRejectsBillableProviderWithoutOperationID(t *testing.T) {
	provider := &publicCreateProvider{}
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager}
	if _, err := app.CreateCloudInstanceTyped(cloud.CreateInstanceOptions{Label: "unsafe"}); err == nil {
		t.Fatal("billable create without operationId was accepted")
	}
	if got := provider.calls.Load(); got != 0 {
		t.Fatalf("provider create calls = %d, want 0", got)
	}
}

func TestCreateMultipleCloudInstancesRejectsMissingBillableOperationID(t *testing.T) {
	provider := &publicCreateProvider{}
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager}
	if _, err := app.CreateMultipleCloudInstancesTyped([]cloud.CreateInstanceOptions{{Label: "unsafe"}}); err == nil ||
		!strings.Contains(err.Error(), "operationId is required") {
		t.Fatalf("missing batch operationId error = %v", err)
	}
	if got := provider.calls.Load(); got != 0 {
		t.Fatalf("provider create calls = %d, want 0", got)
	}
}

func TestCreateCloudInstancePanicDoesNotExposeRecoveredPayload(t *testing.T) {
	operationBase := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(operationBase, "secrets"))
	provider := &panicCreateProvider{}
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: operationBase}

	_, err := app.CreateCloudInstanceTyped(cloud.CreateInstanceOptions{
		OperationID: "panic-operation", Label: "panic",
	})
	if !errors.Is(err, cloud.ErrCreateOutcomePending) {
		t.Fatalf("panic create error = %v, want pending", err)
	}
	if strings.Contains(err.Error(), "api-key-super-secret") || strings.Contains(err.Error(), "provider payload") {
		t.Fatalf("panic payload leaked through create error: %v", err)
	}
}

func TestCancelCloudOperationDetachesWithoutCancelingProviderCreate(t *testing.T) {
	operationBase := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(operationBase, "secrets"))
	provider := &blockingAccountCreateProvider{entered: make(chan struct{}), release: make(chan struct{})}
	registry := cloud.NewRegistry()
	registry.Register("mock", provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("mock"); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: operationBase}

	result := make(chan error, 1)
	go func() {
		_, err := app.CreateCloudInstanceTyped(cloud.CreateInstanceOptions{
			OperationID: "cancel-me",
			Label:       "node",
		})
		result <- err
	}()

	select {
	case <-provider.entered:
	case <-time.After(time.Second):
		t.Fatal("account probe did not start")
	}
	if err := app.CancelCloudOperation("cancel-me"); err != nil {
		t.Fatalf("CancelCloudOperation() error = %v", err)
	}
	status, err := app.GetCloudOperationStatus("cancel-me")
	if err != nil || status.State != "running" {
		t.Fatalf("detached operation status = %#v, err=%v", status, err)
	}
	select {
	case err := <-result:
		if !errors.Is(err, cloud.ErrOperationDetached) {
			t.Fatalf("CreateCloudInstanceTyped() error = %v, want ErrOperationDetached", err)
		}
	case <-time.After(time.Second):
		t.Fatal("detached create waiter did not return")
	}
	close(provider.release)

	// Reusing the same operation ID waits for and returns the original result;
	// it never submits a second billed create after the UI detaches. Wait for
	// the detached background operation to populate its cached result first.
	deadline := time.Now().Add(time.Second)
	for {
		app.cloudCreateMu.Lock()
		completed := !app.cloudCreateOps[cloudCreateOperationKey("mock", "cancel-me")].completed.IsZero()
		app.cloudCreateMu.Unlock()
		if completed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("detached provider create did not complete")
		}
		time.Sleep(5 * time.Millisecond)
	}
	instance, err := app.CreateCloudInstanceTyped(cloud.CreateInstanceOptions{
		OperationID: "cancel-me",
		Label:       "node",
	})
	if err != nil {
		t.Fatalf("rejoin detached operation: %v", err)
	}
	if instance == nil || instance.ID != "one" {
		t.Fatalf("rejoined instance = %#v", instance)
	}
	status, err = app.GetCloudOperationStatus("cancel-me")
	if err != nil || status.State != "succeeded" || status.Instance == nil || status.Instance.ID != "one" {
		t.Fatalf("completed operation status = %#v, err=%v", status, err)
	}
	if got := provider.calls.Load(); got != 1 {
		t.Fatalf("provider create calls = %d, want one continuing call", got)
	}
}

func TestRepairCloudInstanceNeverCreatesReplacementForUnsupportedProvider(t *testing.T) {
	provider := &idempotentCreateProvider{}
	registry := cloud.NewRegistry()
	registry.Register("mock", provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("mock"); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager}

	_, err := app.RepairCloudInstanceTyped("existing")
	if !errors.Is(err, cloud.ErrRepairUnsupported) {
		t.Fatalf("RepairCloudInstanceTyped() error = %v, want ErrRepairUnsupported", err)
	}
	if got := provider.calls.Load(); got != 0 {
		t.Fatalf("repair created %d replacement instances", got)
	}
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

func TestResolveBasePathKeepsHistoricalLinuxDataAcrossPackageSwitch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	legacy := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(filepath.Join(legacy, "data", "cloud"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "data", "cloud", "vultr-nodes.json"), []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got := resolveBasePath("linux", "/usr/lib/privatedeploy/privatedeploy"); got != legacy {
		t.Fatalf("system package selected %q, want historical root %q", got, legacy)
	}
	if got := resolveBasePath("linux", "/tmp/.mount_pd/usr/bin/privatedeploy"); got != legacy {
		t.Fatalf("AppImage selected %q, want historical root %q", got, legacy)
	}
	choice, err := os.ReadFile(filepath.Join(home, ".config", "PrivateDeploy", linuxDataRootChoiceFile))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(choice)) != legacy {
		t.Fatalf("persisted choice = %q, want %q", choice, legacy)
	}
}

func TestLinuxDataRootChoiceDoesNotOverwriteDivergentRoots(t *testing.T) {
	home := t.TempDir()
	canonical := filepath.Join(home, ".local", "share", "PrivateDeploy")
	legacy := filepath.Join(home, ".local", "bin")
	for _, root := range []string{canonical, legacy} {
		if err := os.MkdirAll(filepath.Join(root, "data", "cloud"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	canonicalFile := filepath.Join(canonical, "data", "cloud", "vultr-nodes.json")
	legacyFile := filepath.Join(legacy, "data", "cloud", "vultr-nodes.json")
	if err := os.WriteFile(canonicalFile, []byte("canonical"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyFile, []byte("newer-legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	canonicalTime := time.Unix(1_600_000_000, 0)
	legacyTime := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(canonicalFile, canonicalTime, canonicalTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(legacyFile, legacyTime, legacyTime); err != nil {
		t.Fatal(err)
	}

	if got := chooseLinuxPersistentBasePath(home); got != legacy {
		t.Fatalf("selected %q, want newer root %q", got, legacy)
	}
	if got, _ := os.ReadFile(canonicalFile); string(got) != "canonical" {
		t.Fatalf("canonical conflict was overwritten: %q", got)
	}
	if got, _ := os.ReadFile(legacyFile); string(got) != "newer-legacy" {
		t.Fatalf("legacy conflict was overwritten: %q", got)
	}
}

func TestLinuxDataRootChoiceIgnoresNewInstalledAndRuntimeFiles(t *testing.T) {
	home := t.TempDir()
	canonical := filepath.Join(home, ".local", "share", "PrivateDeploy")
	legacy := filepath.Join(home, ".local", "bin")
	canonicalNode := filepath.Join(canonical, "data", "cloud", "vultr-nodes.json")
	legacyCore := filepath.Join(legacy, "data", "sing-box", "sing-box")
	legacyCache := filepath.Join(legacy, "data", ".cache", "gui.zip")
	legacyOperation := filepath.Join(legacy, "data", "cloud", "operations", "vultr-new.pdop")

	for _, file := range []string{canonicalNode, legacyCore, legacyCache, legacyOperation} {
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(filepath.Base(file)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	oldBusinessTime := time.Unix(1_600_000_000, 0)
	newRuntimeTime := time.Unix(1_900_000_000, 0)
	if err := os.Chtimes(canonicalNode, oldBusinessTime, oldBusinessTime); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{legacyCore, legacyCache, legacyOperation} {
		if err := os.Chtimes(file, newRuntimeTime, newRuntimeTime); err != nil {
			t.Fatal(err)
		}
	}

	if _, score := linuxDataRootActivity(legacy); score != 0 {
		t.Fatalf("legacy runtime-only root score = %d, want 0", score)
	}
	if got := chooseLinuxPersistentBasePath(home); got != canonical {
		t.Fatalf("selected %q, want older durable root %q", got, canonical)
	}
}

func TestLinuxDataRootChoiceUsesRicherDurableStateAndKeepsMarker(t *testing.T) {
	home := t.TempDir()
	canonical := filepath.Join(home, ".local", "share", "PrivateDeploy")
	legacy := filepath.Join(home, ".local", "bin")
	canonicalUser := filepath.Join(canonical, "data", "user.yaml")
	legacyUser := filepath.Join(legacy, "data", "user.yaml")
	legacyNodes := filepath.Join(legacy, "data", "cloud", "vultr-nodes.json")
	for _, file := range []string{canonicalUser, legacyUser, legacyNodes} {
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(filepath.Base(file)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	canonicalTime := time.Unix(1_600_000_000, 0)
	legacyTime := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(canonicalUser, canonicalTime, canonicalTime); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{legacyUser, legacyNodes} {
		if err := os.Chtimes(file, legacyTime, legacyTime); err != nil {
			t.Fatal(err)
		}
	}

	if got := chooseLinuxPersistentBasePath(home); got != legacy {
		t.Fatalf("selected %q, want richer durable root %q", got, legacy)
	}

	// Once persisted, the decision is stable even if the other root changes.
	canonicalNodes := filepath.Join(canonical, "data", "cloud", "digitalocean-nodes.json")
	if err := os.MkdirAll(filepath.Dir(canonicalNodes), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(canonicalNodes, []byte("later canonical data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := chooseLinuxPersistentBasePath(home); got != legacy {
		t.Fatalf("persisted root changed to %q, want %q", got, legacy)
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

func TestResolveBasePathUsesLocalAppDataForWindowsShortSystemInstallPath(t *testing.T) {
	localAppData := t.TempDir()
	t.Setenv("LOCALAPPDATA", localAppData)
	t.Setenv("ProgramFiles", `C:/Program Files`)
	t.Setenv("ProgramFiles(x86)", `C:/Program Files (x86)`)
	t.Setenv("ProgramW6432", `C:/Program Files`)

	got := resolveBasePath("windows", `C:/PROGRA~1/PrivateDeploy/PrivateDeploy.exe`)
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

func TestConfiguredBasePathUsesAbsoluteLauncherOverride(t *testing.T) {
	t.Setenv(basePathEnv, "/home/tester/.local/bin/../bin")

	if got, want := configuredBasePath("/tmp/fallback"), "/home/tester/.local/bin"; got != want {
		t.Fatalf("configuredBasePath() = %q, want %q", got, want)
	}
}

func TestConfiguredBasePathRejectsRelativeOverride(t *testing.T) {
	t.Setenv(basePathEnv, "relative/data")

	if got, want := configuredBasePath("/tmp/fallback"), "/tmp/fallback"; got != want {
		t.Fatalf("configuredBasePath() = %q, want %q", got, want)
	}
}

func TestConfiguredAppNamePreservesLauncherIdentity(t *testing.T) {
	t.Setenv(appNameEnv, "PrivateDeploy")

	if got, want := configuredAppName("PrivateDeploy.bin"), "PrivateDeploy"; got != want {
		t.Fatalf("configuredAppName() = %q, want %q", got, want)
	}
}

func TestConfiguredAppNameRejectsPathValues(t *testing.T) {
	for _, override := range []string{"../PrivateDeploy", `dir\PrivateDeploy`, ".", ".."} {
		t.Run(override, func(t *testing.T) {
			t.Setenv(appNameEnv, override)
			if got, want := configuredAppName("PrivateDeploy.bin"), "PrivateDeploy.bin"; got != want {
				t.Fatalf("configuredAppName() = %q, want %q", got, want)
			}
		})
	}
}
