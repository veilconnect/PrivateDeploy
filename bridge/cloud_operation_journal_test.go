package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

type durableCreateTestBackend struct {
	mu        sync.Mutex
	posts     int
	reconcile int
	finalize  int
	remote    map[string]*cloud.Instance
	ambiguous bool
}

type durableCreateTestProvider struct {
	mockLatencyProvider
	backend *durableCreateTestBackend
	name    string
}

type providerSwitchTestProvider struct {
	mockLatencyProvider
	name    string
	calls   atomic.Int32
	entered chan<- string
	release <-chan struct{}
}

type secretErrorCreateProvider struct {
	mockLatencyProvider
	name         string
	createErr    error
	reconcileErr error
}

func (provider *secretErrorCreateProvider) Name() string { return provider.name }

func (provider *secretErrorCreateProvider) DisplayName() string { return provider.name }

func (provider *secretErrorCreateProvider) CreateInstance(context.Context, *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, provider.createErr
}

func (provider *secretErrorCreateProvider) ReconcileCreateOperation(context.Context, *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	return nil, provider.reconcileErr
}

func (provider *providerSwitchTestProvider) Name() string {
	return provider.name
}

func (provider *providerSwitchTestProvider) DisplayName() string {
	return provider.name
}

func (provider *providerSwitchTestProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	provider.calls.Add(1)
	if provider.entered != nil {
		select {
		case provider.entered <- opts.OperationID:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if provider.release != nil {
		select {
		case <-provider.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return &cloud.Instance{
		ID:       provider.name + "-" + opts.OperationID,
		Provider: provider.name,
		Label:    opts.Label,
	}, nil
}

func (provider *durableCreateTestProvider) Name() string {
	if provider.name != "" {
		return provider.name
	}
	return "mock"
}

func (provider *durableCreateTestProvider) CreateInstance(_ context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	tag := cloud.CreateOperationTag(provider.Name(), opts.OperationID)
	provider.backend.mu.Lock()
	provider.backend.posts++
	instance := &cloud.Instance{ID: "remote-" + opts.OperationID, Provider: provider.Name(), Label: opts.Label}
	if provider.backend.remote == nil {
		provider.backend.remote = make(map[string]*cloud.Instance)
	}
	provider.backend.remote[tag] = instance
	ambiguous := provider.backend.ambiguous
	provider.backend.mu.Unlock()
	if ambiguous {
		return nil, cloud.ErrCreateOutcomePending
	}
	return instance, nil
}

func (provider *durableCreateTestProvider) ReconcileCreateOperation(_ context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	tag := cloud.CreateOperationTag(provider.Name(), opts.OperationID)
	provider.backend.mu.Lock()
	defer provider.backend.mu.Unlock()
	provider.backend.reconcile++
	instance := provider.backend.remote[tag]
	if instance == nil {
		return nil, cloud.ErrCreateOutcomePending
	}
	copy := *instance
	return &copy, nil
}

func (provider *durableCreateTestProvider) FinalizeReconciledCreate(_ context.Context, _ *cloud.CreateInstanceOptions, instance *cloud.Instance) (*cloud.Instance, error) {
	provider.backend.mu.Lock()
	provider.backend.finalize++
	provider.backend.mu.Unlock()
	if instance == nil {
		return nil, cloud.ErrInstanceNotFound
	}
	copy := *instance
	copy.LastDeployWarning = "test finalization completed"
	return &copy, nil
}

func newDurableCreateTestApp(t *testing.T, basePath string, provider *durableCreateTestProvider) *App {
	t.Helper()
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	return &App{CloudManager: manager, cloudOperationBasePath: basePath}
}

func newSecretErrorTestApp(t *testing.T, basePath string, provider *secretErrorCreateProvider) *App {
	t.Helper()
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	return &App{CloudManager: manager, cloudOperationBasePath: basePath}
}

func assertNoCloudOperationSecrets(t *testing.T, value string, secrets ...string) {
	t.Helper()
	for index, secret := range secrets {
		if strings.Contains(value, secret) {
			t.Fatalf("cloud operation output leaked test credential #%d", index+1)
		}
	}
}

func TestDurableCloudCreateRecoversAfterProcessRestartWithoutSecondPost(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	backend := &durableCreateTestBackend{ambiguous: true}
	providerBeforeRestart := &durableCreateTestProvider{backend: backend}
	appBeforeRestart := newDurableCreateTestApp(t, basePath, providerBeforeRestart)
	opts := cloud.CreateInstanceOptions{OperationID: "restart-operation", Label: "restart-node"}

	_, err := appBeforeRestart.performDurableCloudCreate(providerBeforeRestart, &opts)
	if !errors.Is(err, cloud.ErrCreateOutcomePending) {
		t.Fatalf("first create error = %v, want pending outcome", err)
	}
	journalPath := appBeforeRestart.cloudCreateOperationPath(providerBeforeRestart.Name(), opts.OperationID)
	blob, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	if !cloud.IsEncryptedRecordsFile(blob) {
		t.Fatal("create operation journal is not encrypted")
	}
	if info, err := os.Stat(journalPath); err != nil {
		t.Fatal(err)
	} else if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("journal mode = %04o, want 0600", got)
	}

	// A new App/provider has no in-memory call cache. It must use the existing
	// encrypted record and provider marker rather than enter CreateInstance.
	providerAfterRestart := &durableCreateTestProvider{backend: backend}
	appAfterRestart := newDurableCreateTestApp(t, basePath, providerAfterRestart)
	instance, err := appAfterRestart.CreateCloudInstanceTyped(opts)
	if err != nil {
		t.Fatalf("restart reconciliation: %v", err)
	}
	if instance == nil || instance.ID != "remote-restart-operation" {
		t.Fatalf("recovered instance = %#v", instance)
	}
	backend.mu.Lock()
	posts, reconciles, finalizes := backend.posts, backend.reconcile, backend.finalize
	backend.mu.Unlock()
	if posts != 1 {
		t.Fatalf("billable POST count = %d, want exactly 1", posts)
	}
	if reconciles == 0 {
		t.Fatal("restart did not query the provider marker")
	}
	if finalizes != 1 {
		t.Fatalf("restart finalization count = %d, want 1", finalizes)
	}
	record, err := cloud.ReadCreateOperation(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	if record.State != cloud.CreateOperationSucceeded || record.Instance == nil || record.Instance.LastDeployWarning == "" {
		t.Fatalf("terminal journal record = %#v", record)
	}
}

func TestCreateOperationErrorIsSanitizedInMemoryJournalAndIPC(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	const (
		extraSecret  = "desktop-extra-secret-7f1"
		bearerSecret = "desktop.bearer-secret"
		apiSecret    = "desktop-api-secret"
	)
	provider := &secretErrorCreateProvider{
		name: "secret-error-provider",
		createErr: fmt.Errorf(
			"deploy failed: password=%s; Authorization: Bearer %s; api_key=%s\n\x1b[31mprovider detail",
			extraSecret, bearerSecret, apiSecret,
		),
	}
	app := newSecretErrorTestApp(t, basePath, provider)
	opts := cloud.CreateInstanceOptions{
		OperationID: "secret-terminal-operation",
		Label:       "secret-terminal",
		Extra:       map[string]string{"customAuthentication": extraSecret},
	}

	_, createErr := app.CreateCloudInstanceTyped(opts)
	if createErr == nil {
		t.Fatal("malicious provider error unexpectedly succeeded")
	}
	assertNoCloudOperationSecrets(t, createErr.Error(), extraSecret, bearerSecret, apiSecret)
	if !strings.Contains(createErr.Error(), "deploy failed") || !strings.Contains(createErr.Error(), "[REDACTED]") {
		t.Fatalf("sanitized create error lost useful context: %q", createErr)
	}

	record, err := cloud.FindCreateOperation(basePath, opts.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if record.State != cloud.CreateOperationFailed {
		t.Fatalf("operation state = %q, want failed", record.State)
	}
	assertNoCloudOperationSecrets(t, record.LastError, extraSecret, bearerSecret, apiSecret)

	status, err := app.GetCloudOperationStatus(opts.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if status.State != "failed" || status.Error == "" {
		t.Fatalf("operation status = %#v", status)
	}
	assertNoCloudOperationSecrets(t, status.Error, extraSecret, bearerSecret, apiSecret)
}

func TestRestartReconciliationSanitizesJournalStatusAndLog(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	const (
		extraSecret  = "restart-extra-secret-9a2"
		bearerSecret = "restart.bearer-secret"
		apiSecret    = "restart-api-secret"
	)
	provider := &secretErrorCreateProvider{
		name: "secret-reconcile-provider",
		reconcileErr: fmt.Errorf(
			"reconcile failed: password=%s Authorization: Bearer %s token=%s",
			extraSecret, bearerSecret, apiSecret,
		),
	}
	app := newSecretErrorTestApp(t, basePath, provider)
	opts := cloud.CreateInstanceOptions{
		OperationID: "secret-reconcile-operation",
		Label:       "secret-reconcile",
		Extra:       map[string]string{"opaqueProviderValue": extraSecret},
	}
	path := cloud.CreateOperationJournalPath(basePath, provider.Name(), opts.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(path, provider.Name(), opts); err != nil || !created {
		t.Fatalf("prepare reconciliation operation: created=%v err=%v", created, err)
	}

	var logOutput bytes.Buffer
	previousWriter := log.Writer()
	log.SetOutput(&logOutput)
	defer log.SetOutput(previousWriter)
	app.reconcilePendingCloudOperations(context.Background(), provider)

	record, err := cloud.ReadCreateOperation(path)
	if err != nil {
		t.Fatal(err)
	}
	if record.State != cloud.CreateOperationFailed {
		t.Fatalf("reconciled operation state = %q, want failed", record.State)
	}
	assertNoCloudOperationSecrets(t, record.LastError, extraSecret, bearerSecret, apiSecret)
	assertNoCloudOperationSecrets(t, logOutput.String(), extraSecret, bearerSecret, apiSecret)

	status, err := app.GetCloudOperationStatus(opts.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if status.State != "failed" || !strings.Contains(status.Error, "reconcile failed") {
		t.Fatalf("reconciled operation status = %#v", status)
	}
	assertNoCloudOperationSecrets(t, status.Error, extraSecret, bearerSecret, apiSecret)
}

func TestCreateMultipleCloudInstancesUsesStableDurableItemOperations(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	backend := &durableCreateTestBackend{}
	items := []cloud.CreateInstanceOptions{
		{Label: "batch-a", Region: "nrt", Plan: "small"},
		{Label: "batch-b", Region: "fra", Plan: "small"},
	}

	firstApp := newDurableCreateTestApp(t, basePath, &durableCreateTestProvider{backend: backend})
	first, err := firstApp.CreateMultipleCloudInstancesTyped(items)
	if err != nil {
		t.Fatal(err)
	}
	for index, result := range first {
		if !result.Success || result.OperationID == "" || result.State != "succeeded" {
			t.Fatalf("first batch result %d = %#v", index, result)
		}
	}

	// Simulate a whole-process retry. Stable per-item IDs resolve the completed
	// journals and never call the provider's billable method again.
	secondApp := newDurableCreateTestApp(t, basePath, &durableCreateTestProvider{backend: backend})
	second, err := secondApp.CreateMultipleCloudInstancesTyped(items)
	if err != nil {
		t.Fatal(err)
	}
	for index, result := range second {
		if !result.Success || result.ID != first[index].ID {
			t.Fatalf("second batch result %d = %#v, first=%#v", index, result, first[index])
		}
	}
	backend.mu.Lock()
	posts := backend.posts
	backend.mu.Unlock()
	if posts != len(items) {
		t.Fatalf("billable POST count = %d, want %d", posts, len(items))
	}
}

func TestCreateMultipleCloudInstancesReturnsOperationIDForReconciliation(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	backend := &durableCreateTestBackend{ambiguous: true}
	app := newDurableCreateTestApp(t, basePath, &durableCreateTestProvider{backend: backend})
	results, err := app.CreateMultipleCloudInstancesTyped([]cloud.CreateInstanceOptions{{
		Label: "uncertain-batch-node", Region: "nrt", Plan: "small",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].OperationID == "" || results[0].State != "reconciling" || results[0].Success {
		t.Fatalf("ambiguous batch result = %#v", results)
	}
	record, err := cloud.FindCreateOperation(basePath, results[0].OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if record.Provider != "mock" {
		t.Fatalf("operation provider = %q", record.Provider)
	}
	deadline := time.Now().Add(time.Second)
	for record.State != cloud.CreateOperationSucceeded && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		record, err = cloud.FindCreateOperation(basePath, results[0].OperationID)
		if err != nil {
			t.Fatal(err)
		}
	}
	if record.State != cloud.CreateOperationSucceeded {
		t.Fatalf("background marker reconciliation did not converge: %#v", record)
	}
	backend.mu.Lock()
	posts, finalizes := backend.posts, backend.finalize
	backend.mu.Unlock()
	if posts != 1 {
		t.Fatalf("background reconciliation issued %d billable creates", posts)
	}
	if finalizes != 1 || record.Instance == nil || record.Instance.LastDeployWarning == "" {
		t.Fatalf("background finalization count=%d record=%#v", finalizes, record)
	}
}

func TestCreateMultipleCloudInstancesPinsProviderAcrossQueuedItems(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	entered := make(chan string, 5)
	release := make(chan struct{})
	firstProvider := &providerSwitchTestProvider{
		name: "provider-a", entered: entered, release: release,
	}
	secondProvider := &providerSwitchTestProvider{name: "provider-b"}
	registry := cloud.NewRegistry()
	registry.Register(firstProvider.Name(), firstProvider)
	registry.Register(secondProvider.Name(), secondProvider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(firstProvider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: basePath}
	items := make([]cloud.CreateInstanceOptions, 5)
	for index := range items {
		items[index] = cloud.CreateInstanceOptions{
			OperationID: fmt.Sprintf("provider-pinned-%d", index),
			Label:       fmt.Sprintf("node-%d", index),
		}
	}

	type batchResult struct {
		results []MultiDeployResult
		err     error
	}
	done := make(chan batchResult, 1)
	go func() {
		results, err := app.CreateMultipleCloudInstancesTyped(items)
		done <- batchResult{results: results, err: err}
	}()

	// The semaphore admits three items. Switch the manager while the remaining
	// two are still queued; every item must retain the provider chosen above.
	for range 3 {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("batch did not enter the first provider three times")
		}
	}
	if err := manager.SetActiveProvider(secondProvider.Name()); err != nil {
		t.Fatal(err)
	}
	close(release)

	select {
	case outcome := <-done:
		if outcome.err != nil {
			t.Fatal(outcome.err)
		}
		if len(outcome.results) != len(items) {
			t.Fatalf("batch result count = %d, want %d", len(outcome.results), len(items))
		}
		for index, result := range outcome.results {
			if !result.Success || !strings.HasPrefix(result.ID, firstProvider.Name()+"-") {
				t.Fatalf("batch result %d escaped pinned provider: %#v", index, result)
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("provider-pinned batch did not finish")
	}
	if got := firstProvider.calls.Load(); got != int32(len(items)) {
		t.Fatalf("first provider calls = %d, want %d", got, len(items))
	}
	if got := secondProvider.calls.Load(); got != 0 {
		t.Fatalf("second provider received %d queued creates, want 0", got)
	}
}

func TestConcurrentSameOperationIDIsIsolatedByProviderAndExternallyAmbiguous(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	entered := make(chan string, 3)
	release := make(chan struct{})
	firstProvider := &providerSwitchTestProvider{
		name: "provider-a", entered: entered, release: release,
	}
	secondProvider := &providerSwitchTestProvider{
		name: "provider-b", entered: entered, release: release,
	}
	registry := cloud.NewRegistry()
	registry.Register(firstProvider.Name(), firstProvider)
	registry.Register(secondProvider.Name(), secondProvider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(firstProvider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: basePath}
	options := cloud.CreateInstanceOptions{OperationID: "shared-operation", Label: "shared"}

	type createResult struct {
		expectedProvider string
		instance         *cloud.Instance
		err              error
	}
	results := make(chan createResult, 3)
	start := func(provider *providerSwitchTestProvider) {
		go func() {
			instance, err := app.createCloudInstanceForProvider(provider, options)
			results <- createResult{expectedProvider: provider.Name(), instance: instance, err: err}
		}()
	}
	// Two same-provider calls must share one billed request, while the same ID
	// on a second provider is a separate operation with a separate result.
	start(firstProvider)
	start(firstProvider)
	start(secondProvider)
	for range 2 {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("provider-qualified creates did not both enter")
		}
	}

	if _, err := app.GetCloudOperationStatus(options.OperationID); err == nil || !strings.Contains(err.Error(), "multiple providers") {
		t.Fatalf("ambiguous status error = %v", err)
	}
	if err := app.CancelCloudOperation(options.OperationID); err == nil || !strings.Contains(err.Error(), "multiple providers") {
		t.Fatalf("ambiguous cancel error = %v", err)
	}
	if _, err := app.ListPendingCloudOperations(); err == nil || !strings.Contains(err.Error(), "multiple providers") {
		t.Fatalf("ambiguous startup snapshot error = %v", err)
	}
	close(release)

	for range 3 {
		select {
		case result := <-results:
			if result.err != nil {
				t.Fatal(result.err)
			}
			if result.instance == nil || result.instance.Provider != result.expectedProvider ||
				!strings.HasPrefix(result.instance.ID, result.expectedProvider+"-") {
				t.Fatalf("provider result crossed ownership: %#v", result)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("provider-qualified create did not finish")
		}
	}
	if got := firstProvider.calls.Load(); got != 1 {
		t.Fatalf("first provider billed create calls = %d, want 1", got)
	}
	if got := secondProvider.calls.Load(); got != 1 {
		t.Fatalf("second provider billed create calls = %d, want 1", got)
	}
}

func TestCancelCloudOperationAfterRestartIsIdempotentForPendingJournal(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	provider := &providerSwitchTestProvider{name: "provider-a"}
	registry := cloud.NewRegistry()
	registry.Register(provider.Name(), provider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(provider.Name()); err != nil {
		t.Fatal(err)
	}
	options := cloud.CreateInstanceOptions{OperationID: "restart-stop-waiting", Label: "pending"}
	path := cloud.CreateOperationJournalPath(basePath, provider.Name(), options.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(path, provider.Name(), options); err != nil || !created {
		t.Fatalf("prepare restart journal: created=%v err=%v", created, err)
	}

	afterRestart := &App{CloudManager: manager, cloudOperationBasePath: basePath}
	if err := afterRestart.CancelCloudOperation(options.OperationID); err != nil {
		t.Fatalf("first restart Stop waiting: %v", err)
	}
	if err := afterRestart.CancelCloudOperation(options.OperationID); err != nil {
		t.Fatalf("idempotent restart Stop waiting: %v", err)
	}
	if err := cloud.FailCreateOperation(path, errors.New("terminal failure")); err != nil {
		t.Fatal(err)
	}
	if err := afterRestart.CancelCloudOperation(options.OperationID); err == nil || !strings.Contains(err.Error(), "completed") {
		t.Fatalf("terminal Stop waiting error = %v", err)
	}
}

func TestListPendingCloudOperationsReturnsSafeProviderIndependentSnapshots(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	firstProvider := &providerSwitchTestProvider{name: "provider-a"}
	secondProvider := &providerSwitchTestProvider{name: "provider-b"}
	registry := cloud.NewRegistry()
	registry.Register(firstProvider.Name(), firstProvider)
	registry.Register(secondProvider.Name(), secondProvider)
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider(firstProvider.Name()); err != nil {
		t.Fatal(err)
	}
	app := &App{CloudManager: manager, cloudOperationBasePath: basePath}

	pendingOptions := cloud.CreateInstanceOptions{
		OperationID: "pending-a",
		Label:       "Pending A",
		Region:      "nrt",
		Plan:        "small",
		Extra:       map[string]string{"privateKey": "must-not-cross-the-bridge"},
	}
	pendingPath := cloud.CreateOperationJournalPath(basePath, firstProvider.Name(), pendingOptions.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(pendingPath, firstProvider.Name(), pendingOptions); err != nil || !created {
		t.Fatalf("prepare pending operation: created=%v err=%v", created, err)
	}

	reconcilingOptions := cloud.CreateInstanceOptions{
		OperationID: "reconciling-b", Label: "Reconciling B", Region: "fra", Plan: "medium",
	}
	reconcilingPath := cloud.CreateOperationJournalPath(basePath, secondProvider.Name(), reconcilingOptions.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(reconcilingPath, secondProvider.Name(), reconcilingOptions); err != nil || !created {
		t.Fatalf("prepare reconciling operation: created=%v err=%v", created, err)
	}
	if err := cloud.MarkCreateOperationReconciling(reconcilingPath, errors.New("provider response lost")); err != nil {
		t.Fatal(err)
	}

	failedOptions := cloud.CreateInstanceOptions{OperationID: "failed-b", Label: "Failed B"}
	failedPath := cloud.CreateOperationJournalPath(basePath, secondProvider.Name(), failedOptions.OperationID)
	if _, created, err := cloud.PrepareCreateOperation(failedPath, secondProvider.Name(), failedOptions); err != nil || !created {
		t.Fatalf("prepare failed operation: created=%v err=%v", created, err)
	}
	if err := cloud.FailCreateOperation(failedPath, errors.New("quota exceeded")); err != nil {
		t.Fatal(err)
	}

	snapshots, err := app.ListPendingCloudOperations()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshots) != 2 {
		t.Fatalf("pending snapshots = %#v, want two non-terminal records", snapshots)
	}
	byID := make(map[string]CloudOperationSnapshot, len(snapshots))
	for _, snapshot := range snapshots {
		byID[snapshot.OperationID] = snapshot
	}
	if got := byID[pendingOptions.OperationID]; got.Provider != firstProvider.Name() || got.State != "running" ||
		got.Label != pendingOptions.Label || got.Region != pendingOptions.Region || got.Plan != pendingOptions.Plan || got.CreatedAt == "" {
		t.Fatalf("pending snapshot = %#v", got)
	}
	if got := byID[reconcilingOptions.OperationID]; got.Provider != secondProvider.Name() || got.State != "reconciling" {
		t.Fatalf("reconciling snapshot = %#v", got)
	}
	if _, exists := byID[failedOptions.OperationID]; exists {
		t.Fatal("terminal failed operation leaked into pending snapshots")
	}
	payload, err := json.Marshal(snapshots)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(payload), "must-not-cross-the-bridge") || strings.Contains(string(payload), "privateKey") {
		t.Fatalf("startup snapshot exposed operation credentials: %s", payload)
	}
}

func TestListCloudInstancesResumesPendingJournalForNonActiveProvider(t *testing.T) {
	basePath := t.TempDir()
	t.Setenv("PRIVATEDEPLOY_SECRET_STORE_DIR", filepath.Join(basePath, "secrets"))
	backend := &durableCreateTestBackend{ambiguous: true}
	pendingProvider := &durableCreateTestProvider{name: "pending-provider", backend: backend}
	beforeRestart := newDurableCreateTestApp(t, basePath, pendingProvider)
	opts := cloud.CreateInstanceOptions{OperationID: "lost-renderer-operation", Label: "lost-renderer-node"}
	if _, err := beforeRestart.performDurableCloudCreate(pendingProvider, &opts); !errors.Is(err, cloud.ErrCreateOutcomePending) {
		t.Fatalf("initial create error = %v", err)
	}

	registry := cloud.NewRegistry()
	registry.Register("pending-provider", &durableCreateTestProvider{name: "pending-provider", backend: backend})
	registry.Register("active-provider", &durableCreateTestProvider{name: "active-provider", backend: &durableCreateTestBackend{}})
	manager := cloud.NewManager(context.Background(), registry)
	if err := manager.SetActiveProvider("active-provider"); err != nil {
		t.Fatal(err)
	}
	afterRestart := &App{CloudManager: manager, cloudOperationBasePath: basePath}
	if _, err := afterRestart.ListCloudInstancesTyped(); err != nil {
		t.Fatal(err)
	}

	backend.mu.Lock()
	posts, reconciles := backend.posts, backend.reconcile
	backend.mu.Unlock()
	if posts != 1 || reconciles == 0 {
		t.Fatalf("restart scan posts=%d reconciles=%d, want one POST and marker reconciliation", posts, reconciles)
	}
	record, err := cloud.FindCreateOperation(basePath, opts.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if record.Provider != "pending-provider" || record.State != cloud.CreateOperationSucceeded {
		t.Fatalf("resumed record = %#v", record)
	}
	status, err := afterRestart.GetCloudOperationStatus(opts.OperationID)
	if err != nil || status.State != "succeeded" || status.Instance == nil {
		t.Fatalf("provider-independent operation status = %#v, err=%v", status, err)
	}
}
