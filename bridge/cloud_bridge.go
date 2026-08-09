package bridge

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"privatedeploy/bridge/cloud/persistence"
	sshprovider "privatedeploy/bridge/cloud/providers/ssh"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// Per-operation timeouts for cloud calls. Each operation derives its context
// from the app lifecycle context (a.Ctx) so it cancels on shutdown, bounded so
// a hung provider call can't block a bridge method forever. Deploy is generous
// (provisioning routinely takes 2-5 min); list/probe ops are short.
const (
	cloudListOpTimeout    = 45 * time.Second
	cloudProbeOpTimeout   = 2 * time.Minute
	cloudDeployOpTimeout  = 10 * time.Minute
	cloudDestroyOpTimeout = 2 * time.Minute
)

// opCtx returns a context for a single cloud operation, derived from the app
// lifecycle context (so it cancels on shutdown) and bounded by timeout. Falls
// back to context.Background when a.Ctx is unset (headless/tests).
func (a *App) opCtx(timeout time.Duration) (context.Context, context.CancelFunc) {
	parent := a.Ctx
	if parent == nil {
		parent = context.Background()
	}
	return context.WithTimeout(parent, timeout)
}

// CloudProviderInfo represents basic information about a cloud provider
type CloudProviderInfo struct {
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
}

const activeCloudProviderFile = "active-provider"

func (a *App) activeCloudProviderPath() string {
	return filepath.Join(a.cloudOperationJournalBasePath(), "data", "cloud", activeCloudProviderFile)
}

func (a *App) loadActiveCloudProviderChoice() (string, bool) {
	raw, err := os.ReadFile(a.activeCloudProviderPath())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("Warning: failed to read active cloud provider choice: %v", err)
			return "", true
		}
		return "", false
	}
	name := strings.TrimSpace(string(raw))
	if !defaults.IsPublicProvider(name) {
		log.Printf("Warning: ignoring invalid active cloud provider choice %q", name)
		return "", true
	}
	if _, err := a.CloudManager.GetProvider(name); err != nil {
		log.Printf("Warning: ignoring unavailable active cloud provider choice %q: %v", name, err)
		return "", true
	}
	return name, true
}

func (a *App) persistActiveCloudProviderChoice(name string) error {
	if !defaults.IsPublicProvider(name) {
		return fmt.Errorf("provider %s is not available in this build", name)
	}
	path := a.activeCloudProviderPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create cloud state directory: %w", err)
	}
	if err := persistence.WritePrivateFileAtomic(path, []byte(name+"\n")); err != nil {
		return fmt.Errorf("persist active cloud provider: %w", err)
	}
	return nil
}

// inferLegacyActiveCloudProvider migrates data roots created before the active
// provider marker existed. It never reads state contents (which can contain
// credentials); it only compares regular, provider-owned config/node files.
func (a *App) inferLegacyActiveCloudProvider(fallback string) string {
	cloudDir := filepath.Join(a.cloudOperationJournalBasePath(), "data", "cloud")
	var (
		winner     string
		winnerTime time.Time
		tied       bool
	)
	for _, providerName := range a.CloudManager.ListProviders() {
		if !defaults.IsPublicProvider(providerName) {
			continue
		}
		var (
			providerTime time.Time
			hasState     bool
		)
		for _, suffix := range []string{"config.json", "nodes.json"} {
			path := filepath.Join(cloudDir, providerName+"-"+suffix)
			info, err := os.Lstat(path)
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err != nil {
				log.Printf("Warning: cannot inspect legacy cloud state %s: %v", path, err)
				return fallback
			}
			if !info.Mode().IsRegular() {
				log.Printf("Warning: ignoring non-regular legacy cloud state %s", path)
				continue
			}
			hasState = true
			if providerTime.IsZero() || info.ModTime().After(providerTime) {
				providerTime = info.ModTime()
			}
		}
		if !hasState {
			continue
		}
		if winner == "" || providerTime.After(winnerTime) {
			winner = providerName
			winnerTime = providerTime
			tied = false
		} else if providerTime.Equal(winnerTime) {
			tied = true
		}
	}
	if winner == "" || tied {
		return fallback
	}
	return winner
}

// restoreActiveCloudProvider selects the last provider used by this data root.
// This is intentionally backend-owned: a renderer restart or packaging switch
// must not silently fall back to Vultr and make another provider's saved API
// key and nodes appear to have vanished.
func (a *App) restoreActiveCloudProvider(fallback string) error {
	name, markerExists := a.loadActiveCloudProviderChoice()
	if name == "" {
		name = fallback
		if !markerExists {
			name = a.inferLegacyActiveCloudProvider(fallback)
		}
	}
	if err := a.CloudManager.SetActiveProvider(name); err != nil {
		return err
	}
	if !markerExists {
		if err := a.persistActiveCloudProviderChoice(name); err != nil {
			return fmt.Errorf("persist migrated active cloud provider: %w", err)
		}
	}
	return nil
}

func (a *App) ListCloudProvidersTyped() ([]CloudProviderInfo, error) {
	log.Printf("[CloudBridge] ListCloudProvidersTyped called")

	providerNames := a.CloudManager.ListProviders()
	providers := make([]CloudProviderInfo, 0, len(providerNames))

	for _, name := range providerNames {
		if !defaults.IsPublicProvider(name) {
			continue
		}
		provider, err := a.CloudManager.GetProvider(name)
		if err != nil {
			log.Printf("[CloudBridge] Warning: Failed to get provider %s: %v", name, err)
			continue
		}

		providers = append(providers, CloudProviderInfo{
			Name:        provider.Name(),
			DisplayName: provider.DisplayName(),
		})
	}

	return providers, nil
}

// ListCloudProviders returns all available cloud providers
func (a *App) ListCloudProviders() FlagResult {
	providers, err := a.ListCloudProvidersTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list providers: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(providers)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal providers: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Found %d providers: %s", len(providers), string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) SetCloudProviderTyped(providerName string) (*CloudProviderInfo, error) {
	log.Printf("[CloudBridge] SetCloudProviderTyped called with: %s", providerName)
	a.cloudProviderMu.Lock()
	defer a.cloudProviderMu.Unlock()

	if !defaults.IsPublicProvider(providerName) {
		return nil, fmt.Errorf("provider %s is experimental and not available in this build", providerName)
	}

	previous, _ := a.CloudManager.GetActiveProvider()
	if err := a.CloudManager.SetActiveProvider(providerName); err != nil {
		return nil, err
	}
	if err := a.persistActiveCloudProviderChoice(providerName); err != nil {
		if previous != nil {
			_ = a.CloudManager.SetActiveProvider(previous.Name())
		}
		return nil, err
	}

	return a.GetCloudProviderTyped()
}

// SetCloudProvider sets the active cloud provider
func (a *App) SetCloudProvider(providerName string) FlagResult {
	info, err := a.SetCloudProviderTyped(providerName)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to set provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Successfully set active provider to: %s", providerName)
	data, err := json.Marshal(info)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) GetCloudProviderTyped() (*CloudProviderInfo, error) {
	log.Printf("[CloudBridge] GetCloudProviderTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	if !defaults.IsPublicProvider(provider.Name()) {
		return nil, fmt.Errorf("provider %s is experimental and not exposed in this build", provider.Name())
	}

	info := &CloudProviderInfo{
		Name:        provider.Name(),
		DisplayName: provider.DisplayName(),
	}
	return info, nil
}

// GetCloudProvider returns the current active provider
func (a *App) GetCloudProvider() FlagResult {
	info, err := a.GetCloudProviderTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(info)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal provider info: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Current provider: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// redactedAPIKeyPlaceholder is sent to the renderer in place of the real cloud
// API key. The renderer never needs the cleartext key (deploys use the
// backend's secret-store-backed config), so this keeps the key out of webview
// memory while preserving the frontend's "a key is configured" presence checks.
// SaveCloudConfigTyped recognises the placeholder and leaves the stored key
// intact.
const redactedAPIKeyPlaceholder = "__pd_redacted_api_key__"

// loadCloudConfig returns the active provider's config WITH the real API key.
// It is internal-only (never bound to Wails) so cleartext keys do not reach the
// renderer; callers that need the real key (save-restore, backup) use this.
func (a *App) loadCloudConfig() (*cloud.ProviderConfig, error) {
	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	cfg, err := provider.LoadConfig()
	if err != nil {
		return nil, err
	}

	if cfg == nil {
		cfg = &cloud.ProviderConfig{}
	}
	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	return cfg, nil
}

// GetCloudConfigTyped is the Wails-exposed accessor. It returns a clone with the
// API key redacted so the cleartext key never enters the renderer.
func (a *App) GetCloudConfigTyped() (*cloud.ProviderConfig, error) {
	log.Printf("[CloudBridge] GetCloudConfigTyped called")

	cfg, err := a.loadCloudConfig()
	if err != nil {
		return nil, err
	}

	redacted := *cfg
	if strings.TrimSpace(redacted.APIKey) != "" {
		redacted.APIKey = redactedAPIKeyPlaceholder
	}
	return &redacted, nil
}

// GetCloudConfig returns the persisted configuration for the active provider
// (API key redacted, via GetCloudConfigTyped).
func (a *App) GetCloudConfig() FlagResult {
	cfg, err := a.GetCloudConfigTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to load config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal config: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Loaded config for provider %s", cfg.Provider)
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) SaveCloudConfigTyped(cfg cloud.ProviderConfig) error {
	log.Printf("[CloudBridge] SaveCloudConfigTyped called")

	// The renderer only ever sees a redacted placeholder for an existing key.
	// If it sends the placeholder back unchanged, restore the real stored key so
	// a plain save does not wipe it; never persist the literal placeholder.
	if strings.TrimSpace(cfg.APIKey) == redactedAPIKeyPlaceholder {
		if current, err := a.loadCloudConfig(); err == nil && current != nil {
			cfg.APIKey = current.APIKey
		} else {
			cfg.APIKey = ""
		}
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return err
	}

	if cfg.Provider == "" {
		cfg.Provider = provider.Name()
	}
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	if cfg.Provider != provider.Name() {
		return fmt.Errorf("config provider mismatch with active provider")
	}

	if err := provider.ValidateConfig(&cfg); err != nil {
		return err
	}

	return provider.SaveConfig(&cfg)
}

// SaveCloudConfig persists configuration for the active provider
func (a *App) SaveCloudConfig(configJSON string) FlagResult {
	log.Printf("[CloudBridge] SaveCloudConfig called with payload length: %d", len(configJSON))

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse config JSON: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if err := a.SaveCloudConfigTyped(cfg); err != nil {
		log.Printf("[CloudBridge] ERROR: Config validation failed: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Config saved for provider %s (defaultRegion=%s, defaultPlan=%s)", cfg.Provider, cfg.DefaultRegion, cfg.DefaultPlan)
	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) ListCloudInstancesTyped() ([]cloud.Instance, error) {
	log.Printf("[CloudBridge] ListCloudInstancesTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	ctx, cancel := a.opCtx(cloudListOpTimeout)
	defer cancel()
	// A renderer restart can lose its operation ID. Recover every unfinished
	// durable create before listing so a tagged remote server and its journaled
	// credentials become a normal node without any frontend cooperation.
	a.reconcileAllPendingCloudOperations(ctx)
	instances, err := provider.ListInstances(ctx)
	if err != nil {
		return nil, err
	}
	refresher, ok := provider.(cloud.InstanceHealthRefresher)
	if !ok {
		return instances, nil
	}
	// Warning convergence must not turn one list refresh into N sequential
	// multi-second probes. Recheck all warning-bearing nodes concurrently within
	// one short shared budget and retain the original snapshot on probe failure.
	healthCtx, healthCancel := context.WithTimeout(ctx, 3*time.Second)
	defer healthCancel()
	var healthWG sync.WaitGroup
	for index := range instances {
		if strings.TrimSpace(instances[index].LastDeployWarning) == "" {
			continue
		}
		healthWG.Add(1)
		go func(index int) {
			defer healthWG.Done()
			refreshed, refreshErr := refresher.RefreshInstanceHealth(healthCtx, instances[index].ID)
			if refreshErr == nil && refreshed != nil {
				instances[index] = *refreshed
			}
		}(index)
	}
	healthWG.Wait()
	return instances, nil
}

// ListCloudInstances returns all instances for the active provider
func (a *App) ListCloudInstances() FlagResult {
	instances, err := a.ListCloudInstancesTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instances)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instances: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d instances", len(instances))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) CreateCloudInstanceTyped(opts cloud.CreateInstanceOptions) (instance *cloud.Instance, err error) {
	log.Printf("[CloudBridge] CreateCloudInstanceTyped called (options redacted for security)")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	return a.createCloudInstanceForProvider(provider, opts)
}

// createCloudInstanceForProvider keeps the provider selected at the start of
// a user action fixed for its whole lifetime. In particular, queued items in a
// batch must not jump to a different billable provider when the renderer
// changes the active provider while earlier items are still running.
func (a *App) createCloudInstanceForProvider(provider cloud.CloudProvider, opts cloud.CreateInstanceOptions) (instance *cloud.Instance, err error) {
	if provider == nil {
		return nil, errors.New("cloud provider is required")
	}
	operationID := strings.TrimSpace(opts.OperationID)
	if operationID == "" {
		if defaults.IsPublicProvider(provider.Name()) {
			return nil, fmt.Errorf("operationId is required for billable %s creates", provider.DisplayName())
		}
		return a.performCloudCreate(provider, &opts)
	}
	opts.OperationID = operationID
	operationKey := cloudCreateOperationKey(provider.Name(), operationID)

	createCall, owner := a.claimCloudCreate(provider.Name(), operationID)
	if owner {
		// Run the billable provider operation independently of the renderer's
		// wait. "Stop waiting" may detach the UI, but must never cancel an HTTP
		// create after the provider accepted it and strand an unrecorded server.
		operationOpts := opts
		operationOpts.Extra = cloneCloudStringMap(opts.Extra)
		go func() {
			var created *cloud.Instance
			var createErr error
			defer func() {
				if recover() != nil {
					// The panic location cannot prove whether the provider crossed its
					// POST boundary. Never persist or return the panic value: provider
					// payloads and credentials can be embedded in it.
					createErr = fmt.Errorf("%w: cloud create panicked", cloud.ErrCreateOutcomePending)
				}
				createErr = cloud.SanitizeCreateOperationError(createErr, &operationOpts)
				if errors.Is(createErr, cloud.ErrCreateOutcomePending) {
					a.scheduleCloudCreateReconciliation(provider.Name(), operationOpts.OperationID)
				}
				a.finishCloudCreate(operationKey, createCall, created, createErr)
			}()
			created, createErr = a.performDurableCloudCreate(provider, &operationOpts)
		}()
	}
	return a.waitCloudCreate(createCall)
}

func (a *App) cloudCreateOperationPath(provider, operationID string) string {
	return cloud.CreateOperationJournalPath(a.cloudOperationJournalBasePath(), provider, operationID)
}

func (a *App) cloudOperationJournalBasePath() string {
	basePath := strings.TrimSpace(a.cloudOperationBasePath)
	if basePath == "" {
		basePath = strings.TrimSpace(os.Getenv(basePathEnv))
	}
	if basePath == "" {
		basePath = strings.TrimSpace(Env.BasePath)
	}
	if basePath == "" {
		basePath, _ = os.Getwd()
	}
	if absolute, err := filepath.Abs(basePath); err == nil {
		basePath = absolute
	}
	return basePath
}

// performDurableCloudCreate is the cross-process idempotency boundary. The
// operation lock is held from the encrypted pre-POST journal write through the
// terminal result. If a journal already exists, this method may only reconcile
// by the provider marker; it can never invoke CreateInstance again.
func (a *App) performDurableCloudCreate(provider cloud.CloudProvider, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	operationCtx, operationCancel := a.opCtx(cloudDeployOpTimeout)
	defer operationCancel()
	return a.performDurableCloudCreateWithContext(operationCtx, provider, opts)
}

func (a *App) performDurableCloudCreateWithContext(operationCtx context.Context, provider cloud.CloudProvider, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil || strings.TrimSpace(opts.OperationID) == "" {
		return nil, fmt.Errorf("cloud operation ID is required")
	}

	operationPath := a.cloudCreateOperationPath(provider.Name(), opts.OperationID)
	operationLock, err := acquireCloudOperationFileLock(operationCtx, operationPath+".lock")
	if err != nil {
		return nil, err
	}
	defer operationLock.Close()

	record, created, err := cloud.PrepareCreateOperation(operationPath, provider.Name(), *opts)
	if err != nil {
		return nil, err
	}
	operationOpts := record.Options
	operationOpts.OperationJournalPath = operationPath

	if !created {
		switch record.State {
		case cloud.CreateOperationSucceeded:
			if record.Instance == nil {
				return nil, errors.New("completed cloud operation has no instance result")
			}
			return cloneCloudInstance(record.Instance), nil
		case cloud.CreateOperationFailed:
			if record.LastError == "" {
				return nil, cloud.ErrCreateFailed
			}
			return nil, fmt.Errorf("previous cloud create failed: %s", record.LastError)
		}

		reconciler, ok := provider.(cloud.CreateOperationReconciler)
		if !ok {
			reconcileErr := fmt.Errorf("%w: provider %s cannot reconcile a journaled create", cloud.ErrCreateOutcomePending, provider.Name())
			_ = cloud.MarkCreateOperationReconciling(operationPath, reconcileErr)
			return nil, reconcileErr
		}
		instance, reconcileErr := reconciler.ReconcileCreateOperation(operationCtx, &operationOpts)
		if reconcileErr != nil {
			if errors.Is(reconcileErr, cloud.ErrCreateOutcomePending) {
				_ = cloud.MarkCreateOperationReconciling(operationPath, reconcileErr)
				return nil, reconcileErr
			}
			if journalErr := cloud.FailCreateOperation(operationPath, reconcileErr); journalErr != nil {
				return nil, fmt.Errorf("%w: reconcile failed: %v; terminal state could not be persisted: %v", cloud.ErrCreateOutcomePending, reconcileErr, journalErr)
			}
			return nil, reconcileErr
		}
		if instance == nil {
			nilResultErr := fmt.Errorf("%w: provider reconciliation returned no instance", cloud.ErrCreateOutcomePending)
			_ = cloud.MarkCreateOperationReconciling(operationPath, nilResultErr)
			return nil, nilResultErr
		}
		if finalizer, ok := provider.(cloud.ReconciledCreateFinalizer); ok {
			finalized, finalizeErr := finalizer.FinalizeReconciledCreate(operationCtx, &operationOpts, instance)
			if finalizeErr != nil {
				pendingErr := fmt.Errorf("%w: tagged instance %s was recovered but finalization is incomplete: %v", cloud.ErrCreateOutcomePending, instance.ID, finalizeErr)
				_ = cloud.MarkCreateOperationReconciling(operationPath, pendingErr)
				return nil, pendingErr
			}
			if finalized != nil {
				instance = finalized
			}
		}
		if err := cloud.CompleteCreateOperation(operationPath, instance); err != nil {
			return nil, fmt.Errorf("%w: recovered cloud instance but failed to persist completion: %v", cloud.ErrCreateOutcomePending, err)
		}
		return instance, nil
	}

	instance, createErr := a.performCloudCreate(provider, &operationOpts)
	if createErr != nil {
		if errors.Is(createErr, cloud.ErrCreateOutcomePending) {
			_ = cloud.MarkCreateOperationReconciling(operationPath, createErr)
			return nil, createErr
		}
		if journalErr := cloud.FailCreateOperation(operationPath, createErr); journalErr != nil {
			return nil, fmt.Errorf("%w: cloud create failed: %v; terminal state could not be persisted: %v", cloud.ErrCreateOutcomePending, createErr, journalErr)
		}
		return nil, createErr
	}
	if instance == nil {
		nilResultErr := fmt.Errorf("%w: provider create returned no instance", cloud.ErrCreateOutcomePending)
		_ = cloud.MarkCreateOperationReconciling(operationPath, nilResultErr)
		return nil, nilResultErr
	}
	if err := cloud.CompleteCreateOperation(operationPath, instance); err != nil {
		return nil, fmt.Errorf("%w: cloud instance %s was created but completion could not be journaled: %v", cloud.ErrCreateOutcomePending, instance.ID, err)
	}
	return instance, nil
}

func (a *App) reconcilePendingCloudOperations(ctx context.Context, provider cloud.CloudProvider) {
	if _, ok := provider.(cloud.CreateOperationReconciler); !ok {
		return
	}
	records, err := cloud.ListCreateOperations(a.cloudOperationJournalBasePath(), provider.Name())
	if err != nil {
		log.Printf("[CloudBridge] durable create scan failed for %s: %v", provider.Name(), err)
		return
	}
	reconcileCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	sem := make(chan struct{}, 3)
	for index := range records {
		record := records[index]
		if record.State == cloud.CreateOperationSucceeded || record.State == cloud.CreateOperationFailed ||
			a.cloudCreateIsRunning(provider.Name(), record.OperationID) || a.cloudReconcileIsRunning(provider.Name(), record.OperationID) {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-reconcileCtx.Done():
				return
			}
			_, reconcileErr := a.performDurableCloudCreateWithContext(reconcileCtx, provider, &record.Options)
			reconcileErr = cloud.SanitizeCreateOperationError(reconcileErr, &record.Options)
			if errors.Is(reconcileErr, cloud.ErrCreateOutcomePending) {
				a.scheduleCloudCreateReconciliation(provider.Name(), record.OperationID)
			} else if reconcileErr != nil {
				log.Printf("[CloudBridge] durable create %s reconciliation failed: %v", record.OperationID, reconcileErr)
			}
		}()
	}
	wg.Wait()
}

func (a *App) reconcileAllPendingCloudOperations(ctx context.Context) {
	providerNames := a.CloudManager.ListProviders()
	var wg sync.WaitGroup
	for _, providerName := range providerNames {
		provider, err := a.CloudManager.GetProvider(providerName)
		if err != nil {
			continue
		}
		if _, ok := provider.(cloud.CreateOperationReconciler); !ok {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.reconcilePendingCloudOperations(ctx, provider)
		}()
	}
	wg.Wait()
}

func (a *App) cloudCreateIsRunning(providerName, operationID string) bool {
	a.cloudCreateMu.Lock()
	defer a.cloudCreateMu.Unlock()
	call := a.cloudCreateOps[cloudCreateOperationKey(providerName, operationID)]
	return call != nil && call.completed.IsZero()
}

func (a *App) cloudReconcileIsRunning(providerName, operationID string) bool {
	key := strings.TrimSpace(providerName) + "\x00" + strings.TrimSpace(operationID)
	a.cloudReconcileMu.Lock()
	defer a.cloudReconcileMu.Unlock()
	_, running := a.cloudReconcileOps[key]
	return running
}

// scheduleCloudCreateReconciliation keeps querying the exact provider marker
// after an ambiguous response. It never enters a new-create path because the
// durable journal already exists. One worker per provider/operation survives
// renderer detaches; ListCloudInstances also restarts it after an app restart.
func (a *App) scheduleCloudCreateReconciliation(providerName, operationID string) {
	providerName = strings.TrimSpace(providerName)
	operationID = strings.TrimSpace(operationID)
	if providerName == "" || operationID == "" {
		return
	}
	key := providerName + "\x00" + operationID
	a.cloudReconcileMu.Lock()
	if a.cloudReconcileOps == nil {
		a.cloudReconcileOps = make(map[string]struct{})
	}
	if _, running := a.cloudReconcileOps[key]; running {
		a.cloudReconcileMu.Unlock()
		return
	}
	a.cloudReconcileOps[key] = struct{}{}
	a.cloudReconcileMu.Unlock()

	go func() {
		defer func() {
			a.cloudReconcileMu.Lock()
			delete(a.cloudReconcileOps, key)
			a.cloudReconcileMu.Unlock()
		}()
		provider, err := a.CloudManager.GetProvider(providerName)
		if err != nil {
			return
		}
		parent := a.Ctx
		if parent == nil {
			parent = context.Background()
		}
		workerCtx, workerCancel := context.WithTimeout(parent, cloudDeployOpTimeout)
		defer workerCancel()
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			operationPath := a.cloudCreateOperationPath(providerName, operationID)
			record, readErr := cloud.ReadCreateOperation(operationPath)
			if readErr != nil || record.State == cloud.CreateOperationSucceeded || record.State == cloud.CreateOperationFailed {
				return
			}
			attemptCtx, attemptCancel := context.WithTimeout(workerCtx, 20*time.Second)
			_, reconcileErr := a.performDurableCloudCreateWithContext(attemptCtx, provider, &record.Options)
			attemptCancel()
			if reconcileErr == nil || !errors.Is(reconcileErr, cloud.ErrCreateOutcomePending) {
				return
			}
			select {
			case <-workerCtx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}

func cloneCloudStringMap(input map[string]string) map[string]string {
	if input == nil {
		return nil
	}
	clone := make(map[string]string, len(input))
	for key, value := range input {
		clone[key] = value
	}
	return clone
}

func (a *App) performCloudCreate(provider cloud.CloudProvider, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	ctx, cancel := a.opCtx(cloudDeployOpTimeout)
	defer cancel()
	if reporter, ok := provider.(cloud.AccountStatusReporter); ok {
		probeCtx, probeCancel := context.WithTimeout(ctx, 10*time.Second)
		status, statusErr := reporter.GetAccountStatus(probeCtx)
		probeCancel()
		if statusErr == nil && status != nil && !status.CanDeploy {
			msg := status.Message
			if msg == "" {
				msg = fmt.Sprintf("provider account is in state %q and cannot deploy", status.State)
			}
			log.Printf("[CloudBridge] Refusing deploy: provider=%s state=%s", provider.Name(), status.State)
			return nil, fmt.Errorf("cannot deploy on %s: %s", provider.DisplayName(), msg)
		}
	}

	return provider.CreateInstance(ctx, opts)
}

func (a *App) waitCloudCreate(call *cloudCreateCall) (*cloud.Instance, error) {
	// Prefer a completed result when both completion and an earlier detach are
	// observable (for example, a later call reuses the same operation ID).
	select {
	case <-call.done:
		return cloneCloudInstance(call.instance), call.err
	default:
	}

	waitCtx, cancel := a.opCtx(cloudDeployOpTimeout)
	defer cancel()
	select {
	case <-call.done:
		return cloneCloudInstance(call.instance), call.err
	case <-call.detached:
		return nil, cloud.ErrOperationDetached
	case <-waitCtx.Done():
		return nil, waitCtx.Err()
	}
}

func cloudCreateOperationKey(providerName, operationID string) string {
	return strings.TrimSpace(providerName) + "\x00" + strings.TrimSpace(operationID)
}

func cloudOperationProviderConflictError(operationID string) error {
	return fmt.Errorf("cloud operation ID %q belongs to multiple providers", strings.TrimSpace(operationID))
}

// findCloudCreateCallLocked resolves an externally visible operation ID. The
// in-memory map is provider-qualified so two providers can safely own the same
// client-generated ID, but an unqualified UI lookup must fail closed when that
// ID is ambiguous.
func (a *App) findCloudCreateCallLocked(operationID string) (*cloudCreateCall, error) {
	operationID = strings.TrimSpace(operationID)
	var match *cloudCreateCall
	for _, call := range a.cloudCreateOps {
		if call == nil || call.operationID != operationID {
			continue
		}
		if match != nil && match.providerName != call.providerName {
			return nil, cloudOperationProviderConflictError(operationID)
		}
		match = call
	}
	return match, nil
}

// CancelCloudOperation detaches the desktop from an in-flight create operation.
// The provider operation continues in the background so a request accepted
// remotely cannot become an unrecorded, invisible billable server.
func (a *App) CancelCloudOperation(operationID string) error {
	operationID = strings.TrimSpace(operationID)
	if operationID == "" {
		return fmt.Errorf("cloud operation ID is required")
	}

	// Resolve the durable owner as well as the in-memory owner. This catches an
	// old record for provider A while provider B has just claimed the same ID.
	record, journalErr := cloud.FindCreateOperation(a.cloudOperationJournalBasePath(), operationID)
	if journalErr != nil && !errors.Is(journalErr, os.ErrNotExist) {
		return journalErr
	}

	a.cloudCreateMu.Lock()
	call, callErr := a.findCloudCreateCallLocked(operationID)
	if callErr != nil {
		a.cloudCreateMu.Unlock()
		return callErr
	}
	if call != nil && journalErr == nil && record.Provider != call.providerName {
		a.cloudCreateMu.Unlock()
		return cloudOperationProviderConflictError(operationID)
	}
	if call != nil && call.isDetached {
		a.cloudCreateMu.Unlock()
		return nil
	}
	if call != nil && call.completed.IsZero() {
		call.isDetached = true
		close(call.detached)
		a.cloudCreateMu.Unlock()
		return nil
	}
	a.cloudCreateMu.Unlock()

	if journalErr == nil {
		switch record.State {
		case cloud.CreateOperationSucceeded, cloud.CreateOperationFailed:
			return fmt.Errorf("cloud operation already completed")
		default:
			// A renderer restarted, so there is no waiter left to detach. Treat
			// Stop waiting as an idempotent UI action and keep reconciliation alive.
			provider, providerErr := a.CloudManager.GetProvider(record.Provider)
			if providerErr == nil {
				if _, ok := provider.(cloud.CreateOperationReconciler); ok {
					a.scheduleCloudCreateReconciliation(record.Provider, operationID)
				}
			}
			return nil
		}
	}
	return fmt.Errorf("cloud operation not found or already completed")
}

// CloudOperationStatus is a non-blocking snapshot used by a detached renderer
// to reconcile the original create without ever resubmitting it.
type CloudOperationStatus struct {
	State    string          `json:"state"`
	Instance *cloud.Instance `json:"instance,omitempty"`
	Error    string          `json:"error,omitempty"`
}

func safeCloudOperationStatusError(message string, opts *cloud.CreateInstanceOptions) string {
	if strings.TrimSpace(message) == "" {
		return ""
	}
	return cloud.SanitizeCreateOperationError(errors.New(message), opts).Error()
}

// CloudOperationSnapshot is the credential-free startup view of a durable
// create. Never expose CreateOperationRecord directly: its options and
// provider data can contain generated protocol credentials or API material.
type CloudOperationSnapshot struct {
	OperationID string `json:"operationId"`
	Provider    string `json:"provider"`
	State       string `json:"state"`
	Label       string `json:"label"`
	Region      string `json:"region"`
	Plan        string `json:"plan"`
	CreatedAt   string `json:"createdAt"`
	UpdatedAt   string `json:"updatedAt"`
}

// ListPendingCloudOperations lets a new renderer restore honest
// placeholders for every durable non-terminal create, including operations
// owned by a provider that is no longer active.
func (a *App) ListPendingCloudOperations() ([]CloudOperationSnapshot, error) {
	basePath := a.cloudOperationJournalBasePath()
	records, err := cloud.ListPendingCreateOperations(basePath)
	if err != nil {
		return nil, fmt.Errorf("list pending cloud operations: %w", err)
	}
	snapshots := make([]CloudOperationSnapshot, 0, len(records))
	for _, record := range records {
		resolved, resolveErr := cloud.FindCreateOperation(basePath, record.OperationID)
		if resolveErr != nil {
			return nil, fmt.Errorf("resolve pending cloud operation %q: %w", record.OperationID, resolveErr)
		}
		if resolved.Provider != record.Provider {
			return nil, cloudOperationProviderConflictError(record.OperationID)
		}
		state := "running"
		if record.State == cloud.CreateOperationSubmitted || record.State == cloud.CreateOperationReconciling {
			state = "reconciling"
		}
		snapshot := CloudOperationSnapshot{
			OperationID: record.OperationID,
			Provider:    record.Provider,
			State:       state,
			Label:       record.Options.Label,
			Region:      record.Options.Region,
			Plan:        record.Options.Plan,
		}
		if !record.CreatedAt.IsZero() {
			snapshot.CreatedAt = record.CreatedAt.UTC().Format(time.RFC3339Nano)
		}
		if !record.UpdatedAt.IsZero() {
			snapshot.UpdatedAt = record.UpdatedAt.UTC().Format(time.RFC3339Nano)
		}
		snapshots = append(snapshots, snapshot)
	}
	for _, record := range records {
		// Reading the startup snapshot also resumes the exact provider-marker
		// reconciliation. Providers without reconciliation support are left
		// visible instead of launching a worker that can never converge.
		provider, providerErr := a.CloudManager.GetProvider(record.Provider)
		if providerErr == nil {
			if _, ok := provider.(cloud.CreateOperationReconciler); ok {
				a.scheduleCloudCreateReconciliation(record.Provider, record.OperationID)
			}
		}
	}
	return snapshots, nil
}

func (a *App) GetCloudOperationStatus(operationID string) (*CloudOperationStatus, error) {
	operationID = strings.TrimSpace(operationID)
	if operationID == "" {
		return nil, fmt.Errorf("cloud operation ID is required")
	}

	record, journalErr := cloud.FindCreateOperation(a.cloudOperationJournalBasePath(), operationID)
	if journalErr != nil && !errors.Is(journalErr, os.ErrNotExist) {
		return nil, journalErr
	}

	a.cloudCreateMu.Lock()
	call, callErr := a.findCloudCreateCallLocked(operationID)
	if callErr != nil {
		a.cloudCreateMu.Unlock()
		return nil, callErr
	}
	if call != nil && journalErr == nil && record.Provider != call.providerName {
		a.cloudCreateMu.Unlock()
		return nil, cloudOperationProviderConflictError(operationID)
	}
	var (
		callRunning  bool
		callInstance *cloud.Instance
		createErr    error
	)
	if call != nil {
		callRunning = call.completed.IsZero()
		callInstance = cloneCloudInstance(call.instance)
		createErr = call.err
	}
	a.cloudCreateMu.Unlock()

	if call != nil {
		if callRunning {
			return &CloudOperationStatus{State: "running"}, nil
		}
		if createErr == nil {
			return &CloudOperationStatus{State: "succeeded", Instance: callInstance}, nil
		}
		if !errors.Is(createErr, cloud.ErrCreateOutcomePending) {
			safeErr := cloud.SanitizeCreateOperationError(createErr, nil)
			return &CloudOperationStatus{State: "failed", Error: safeErr.Error()}, nil
		}
		if errors.Is(journalErr, os.ErrNotExist) {
			safeErr := cloud.SanitizeCreateOperationError(createErr, nil)
			return &CloudOperationStatus{State: "reconciling", Error: safeErr.Error()}, nil
		}
	}
	if errors.Is(journalErr, os.ErrNotExist) {
		return nil, fmt.Errorf("cloud operation not found")
	}
	switch record.State {
	case cloud.CreateOperationSucceeded:
		return &CloudOperationStatus{State: "succeeded", Instance: cloneCloudInstance(record.Instance)}, nil
	case cloud.CreateOperationFailed:
		return &CloudOperationStatus{State: "failed", Error: safeCloudOperationStatusError(record.LastError, &record.Options)}, nil
	case cloud.CreateOperationSubmitted, cloud.CreateOperationReconciling:
		a.scheduleCloudCreateReconciliation(record.Provider, operationID)
		return &CloudOperationStatus{State: "reconciling", Error: safeCloudOperationStatusError(record.LastError, &record.Options)}, nil
	default:
		return &CloudOperationStatus{State: "running", Error: safeCloudOperationStatusError(record.LastError, &record.Options)}, nil
	}
}

// claimCloudCreate provides in-process idempotency for one provider-qualified
// operation. Concurrent duplicates on that provider share one result; the same
// client-generated ID on another provider remains an independent durable
// operation and cannot receive the first provider's result.
func (a *App) claimCloudCreate(providerName, operationID string) (*cloudCreateCall, bool) {
	a.cloudCreateMu.Lock()
	defer a.cloudCreateMu.Unlock()
	key := cloudCreateOperationKey(providerName, operationID)
	if a.cloudCreateOps == nil {
		a.cloudCreateOps = make(map[string]*cloudCreateCall)
	}
	cutoff := time.Now().Add(-time.Hour)
	for existingKey, call := range a.cloudCreateOps {
		if !call.completed.IsZero() && (call.completed.Before(cutoff) || errors.Is(call.err, cloud.ErrCreateOutcomePending)) {
			delete(a.cloudCreateOps, existingKey)
		}
	}
	if call, ok := a.cloudCreateOps[key]; ok {
		return call, false
	}
	call := &cloudCreateCall{
		providerName: strings.TrimSpace(providerName),
		operationID:  strings.TrimSpace(operationID),
		done:         make(chan struct{}),
		detached:     make(chan struct{}),
	}
	a.cloudCreateOps[key] = call
	return call, true
}

func (a *App) finishCloudCreate(key string, call *cloudCreateCall, instance *cloud.Instance, err error) {
	a.cloudCreateMu.Lock()
	defer a.cloudCreateMu.Unlock()
	current, ok := a.cloudCreateOps[key]
	if !ok || current != call || !call.completed.IsZero() {
		return
	}
	call.instance = cloneCloudInstance(instance)
	call.err = err
	call.completed = time.Now()
	close(call.done)
}

func cloneCloudInstance(instance *cloud.Instance) *cloud.Instance {
	if instance == nil {
		return nil
	}
	clone := *instance
	return &clone
}

// CloudAccountStatus is the wire envelope returned by GetCloudProviderAccountStatus.
// Providers that do not implement [cloud.AccountStatusReporter] are reported as
// state="active" so the UI never blocks them on a missing capability.
type CloudAccountStatus struct {
	Provider  string    `json:"provider"`
	Supported bool      `json:"supported"`
	State     string    `json:"state"`
	Message   string    `json:"message,omitempty"`
	CanDeploy bool      `json:"canDeploy"`
	CheckedAt time.Time `json:"checkedAt"`
}

func (a *App) GetCloudProviderAccountStatusTyped(providerName string) (*CloudAccountStatus, error) {
	log.Printf("[CloudBridge] GetCloudProviderAccountStatusTyped called for %s", providerName)

	provider, err := a.CloudManager.GetProvider(providerName)
	if err != nil {
		return nil, err
	}

	reporter, ok := provider.(cloud.AccountStatusReporter)
	if !ok {
		return &CloudAccountStatus{
			Provider:  provider.Name(),
			Supported: false,
			State:     "active",
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	}

	probeCtx, cancel := a.opCtx(10 * time.Second)
	defer cancel()
	status, err := reporter.GetAccountStatus(probeCtx)
	if err != nil {
		return nil, err
	}
	if status == nil {
		return &CloudAccountStatus{
			Provider:  provider.Name(),
			Supported: true,
			State:     "unknown",
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	}
	return &CloudAccountStatus{
		Provider:  provider.Name(),
		Supported: true,
		State:     status.State,
		Message:   status.Message,
		CanDeploy: status.CanDeploy,
		CheckedAt: status.CheckedAt,
	}, nil
}

// GetCloudProviderAccountStatus returns the upstream account status for the
// named provider. Used by the UI to grey-out provider chips and disable the
// deploy button when an account is locked or has an invalid key.
func (a *App) GetCloudProviderAccountStatus(providerName string) FlagResult {
	status, err := a.GetCloudProviderAccountStatusTyped(providerName)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: account status probe failed: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}
	data, err := json.Marshal(status)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: string(data)}
}

// CreateCloudInstance creates a new instance on the active provider
func (a *App) CreateCloudInstance(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateCloudInstance called (options redacted for security)")

	var opts cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to parse options: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	instance, err := a.CreateCloudInstanceTyped(opts)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to create instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instance)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Created instance %s", instance.ID)
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) DestroyCloudInstanceTyped(instanceID string) error {
	log.Printf("[CloudBridge] DestroyCloudInstanceTyped called for instance: %s", instanceID)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return err
	}

	ctx, cancel := a.opCtx(cloudDestroyOpTimeout)
	defer cancel()
	return provider.DestroyInstance(ctx, instanceID)
}

// DestroyCloudInstance destroys an instance on the active provider
func (a *App) DestroyCloudInstance(instanceID string) FlagResult {
	if err := a.DestroyCloudInstanceTyped(instanceID); err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to destroy instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Destroyed instance %s", instanceID)
	return FlagResult{Flag: true, Data: "Instance destroyed successfully"}
}

func (a *App) RepairCloudInstanceTyped(instanceID string) (*cloud.Instance, error) {
	log.Printf("[CloudBridge] RepairCloudInstanceTyped called for instance: %s", instanceID)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	if repairer, ok := provider.(cloud.InstanceRepairer); ok {
		ctx, cancel := a.opCtx(cloudDeployOpTimeout)
		defer cancel()
		return repairer.RepairInstance(ctx, instanceID)
	}

	return nil, fmt.Errorf("%w: %s", cloud.ErrRepairUnsupported, provider.DisplayName())
}

// RepairCloudInstance repairs/redeploys an instance on the active provider.
func (a *App) RepairCloudInstance(instanceID string) FlagResult {
	instance, err := a.RepairCloudInstanceTyped(instanceID)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to repair instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(instance)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal repaired instance: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Repair/redeploy submitted for instance %s", instanceID)
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListCloudRegionsTyped() ([]cloud.Region, error) {
	log.Printf("[CloudBridge] ListCloudRegionsTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	ctx, cancel := a.opCtx(cloudListOpTimeout)
	defer cancel()
	return provider.ListRegions(ctx)
}

// ListCloudRegions returns all regions for the active provider
func (a *App) ListCloudRegions() FlagResult {
	regions, err := a.ListCloudRegionsTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(regions)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d regions", len(regions))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListCloudPlansTyped() ([]cloud.Plan, error) {
	log.Printf("[CloudBridge] ListCloudPlansTyped called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	ctx, cancel := a.opCtx(cloudListOpTimeout)
	defer cancel()
	return provider.ListPlans(ctx, "")
}

// ListCloudPlans returns all plans for the active provider
func (a *App) ListCloudPlans() FlagResult {
	plans, err := a.ListCloudPlansTyped()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal plans: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d plans", len(plans))
	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListCloudAvailabilityTyped(region string) ([]string, error) {
	log.Printf("[CloudBridge] ListCloudAvailabilityTyped called for region: %s", region)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}

	ctx, cancel := a.opCtx(cloudListOpTimeout)
	defer cancel()
	return provider.ListAvailability(ctx, region)
}

// ListCloudAvailability returns plan availability for the active provider
func (a *App) ListCloudAvailability(region string) FlagResult {
	plans, err := a.ListCloudAvailabilityTyped(region)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to list availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(plans)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal availability: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Listed %d available plans for region %s", len(plans), region)
	return FlagResult{Flag: true, Data: string(data)}
}

// TestCloudRegionLatency tests latency for a specific region on the active provider
func (a *App) TestCloudRegionLatency(regionCode string) FlagResult {
	log.Printf("[CloudBridge] TestCloudRegionLatency called for region: %s", regionCode)

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	tester, ok := provider.(cloud.LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx, cancel := a.opCtx(cloudProbeOpTimeout)
	defer cancel()
	result, err := tester.TestRegionLatency(ctx, regionCode)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to test region latency: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal latency result: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Latency test completed for region %s: %s", regionCode, string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// TestAllCloudRegions tests latency for all regions on the active provider
func (a *App) TestAllCloudRegions() FlagResult {
	log.Printf("[CloudBridge] TestAllCloudRegions called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	tester, ok := provider.(cloud.LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx, cancel := a.opCtx(cloudProbeOpTimeout)
	defer cancel()
	results, err := tester.TestAllRegions(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to test all regions: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(results)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal latency results: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Latency test completed for all regions")
	return FlagResult{Flag: true, Data: string(data)}
}

// GetFastestCloudRegion returns the fastest available region based on latency test
func (a *App) GetFastestCloudRegion() FlagResult {
	log.Printf("[CloudBridge] GetFastestCloudRegion called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	tester, ok := provider.(cloud.LatencyTester)
	if !ok {
		errMsg := "latency testing not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx, cancel := a.opCtx(cloudProbeOpTimeout)
	defer cancel()
	result, err := tester.GetFastestRegion(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to get fastest region: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal fastest region: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Fastest region: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// CleanInvalidCloudNodes removes node records with incomplete proxy configuration
func (a *App) CleanInvalidCloudNodes() FlagResult {
	log.Printf("[CloudBridge] CleanInvalidCloudNodes called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudBridge] ERROR: No active provider: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Check if provider supports node cleaning
	type NodeCleaner interface {
		CleanInvalidNodes(ctx context.Context) (int, error)
	}

	cleaner, ok := provider.(NodeCleaner)
	if !ok {
		errMsg := "node cleaning not supported for this provider"
		log.Printf("[CloudBridge] ERROR: %s (provider=%s)", errMsg, provider.Name())
		return FlagResult{Flag: false, Data: errMsg}
	}

	ctx, cancel := a.opCtx(cloudProbeOpTimeout)
	defer cancel()
	removed, err := cleaner.CleanInvalidNodes(ctx)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to clean invalid nodes: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	result := map[string]interface{}{
		"provider": provider.Name(),
		"removed":  removed,
	}

	data, err := json.Marshal(result)
	if err != nil {
		log.Printf("[CloudBridge] ERROR: Failed to marshal result: %v", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Cleaned %d invalid nodes for provider %s", removed, provider.Name())
	return FlagResult{Flag: true, Data: string(data)}
}

// TestSSHConnection tests SSH connectivity with the given configuration
func (a *App) TestSSHConnectionTyped(extra map[string]string) (*sshprovider.ServerInfo, error) {
	log.Printf("[CloudBridge] TestSSHConnectionTyped called")

	provider, err := a.CloudManager.GetProvider("ssh")
	if err != nil {
		return nil, fmt.Errorf("SSH provider not registered: %w", err)
	}

	sshProvider, ok := provider.(*sshprovider.Provider)
	if !ok {
		return nil, fmt.Errorf("failed to get SSH provider instance")
	}

	return sshProvider.TestConnection(extra)
}

func (a *App) TestSSHConnection(configJSON string) FlagResult {
	log.Printf("[CloudBridge] TestSSHConnection called")

	var extra map[string]string
	if err := json.Unmarshal([]byte(configJSON), &extra); err != nil {
		return FlagResult{Flag: false, Data: "invalid config JSON: " + err.Error()}
	}

	info, err := a.TestSSHConnectionTyped(extra)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(info)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] SSH connection test success: %s", string(data))
	return FlagResult{Flag: true, Data: string(data)}
}

// SetupSSHEventEmitter configures the SSH provider to emit Wails events.
// Called from OnStartup when the context is available.
func (a *App) SetupSSHEventEmitter() {
	provider, err := a.CloudManager.GetProvider("ssh")
	if err != nil {
		return
	}
	sshProvider, ok := provider.(*sshprovider.Provider)
	if !ok {
		return
	}
	sshProvider.SetEventEmitter(func(eventName string, data ...interface{}) {
		runtime.EventsEmit(a.Ctx, eventName, data...)
	})
}

// MultiDeployResult holds the result of a batch deployment.
type MultiDeployResult struct {
	ID          string `json:"id"`
	OperationID string `json:"operationId"`
	State       string `json:"state"`
	Success     bool   `json:"success"`
	Error       string `json:"error,omitempty"`
}

// CreateMultipleCloudInstances deploys multiple instances in parallel (max 3 concurrent).
func (a *App) CreateMultipleCloudInstancesTyped(optsList []cloud.CreateInstanceOptions) ([]MultiDeployResult, error) {
	log.Printf("[CloudBridge] CreateMultipleCloudInstancesTyped called")

	if len(optsList) == 0 {
		return nil, fmt.Errorf("no instances to create")
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	if defaults.IsPublicProvider(provider.Name()) {
		for index, opts := range optsList {
			if strings.TrimSpace(opts.OperationID) == "" {
				return nil, fmt.Errorf("operationId is required for billable %s batch item %d", provider.DisplayName(), index)
			}
		}
	}
	batchFingerprintInput := make([]cloud.CreateInstanceOptions, len(optsList))
	copy(batchFingerprintInput, optsList)
	for index := range batchFingerprintInput {
		batchFingerprintInput[index].OperationJournalPath = ""
	}
	batchPayload, err := json.Marshal(struct {
		Provider string                        `json:"provider"`
		Items    []cloud.CreateInstanceOptions `json:"items"`
	}{Provider: provider.Name(), Items: batchFingerprintInput})
	if err != nil {
		return nil, fmt.Errorf("fingerprint multi-deploy request: %w", err)
	}
	batchDigest := sha256.Sum256(batchPayload)

	results := make([]MultiDeployResult, len(optsList))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 3) // max 3 concurrent deploys

	for i, opts := range optsList {
		if strings.TrimSpace(opts.OperationID) == "" {
			itemDigest := sha256.Sum256(append(batchDigest[:], byte(i>>24), byte(i>>16), byte(i>>8), byte(i)))
			opts.OperationID = fmt.Sprintf("batch-%x", itemDigest[:16])
		}
		wg.Add(1)
		go func(idx int, o cloud.CreateInstanceOptions) {
			defer wg.Done()
			sem <- struct{}{}        // acquire
			defer func() { <-sem }() // release

			if a.Ctx != nil {
				runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, "deploying", o.Label, o.OperationID)
			}

			// Route every item through the same account gate, in-process sharing,
			// encrypted durable journal and provider-marker reconciliation as a
			// single deploy. A batch retry therefore cannot bypass idempotency.
			instance, err := a.createCloudInstanceForProvider(provider, o)
			if err != nil {
				state := "failed"
				if errors.Is(err, cloud.ErrCreateOutcomePending) {
					state = "reconciling"
				}
				results[idx] = MultiDeployResult{OperationID: o.OperationID, State: state, Success: false, Error: err.Error()}
				if a.Ctx != nil {
					runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, state, err.Error(), o.OperationID)
				}
				return
			}

			results[idx] = MultiDeployResult{ID: instance.ID, OperationID: o.OperationID, State: "succeeded", Success: true}
			if a.Ctx != nil {
				runtime.EventsEmit(a.Ctx, "cloud:multi:progress", idx, "ready", instance.ID, o.OperationID)
			}
		}(i, opts)
	}

	wg.Wait()
	return results, nil
}

func (a *App) CreateMultipleCloudInstances(optionsJSON string) FlagResult {
	log.Printf("[CloudBridge] CreateMultipleCloudInstances called")

	var optsList []cloud.CreateInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &optsList); err != nil {
		return FlagResult{Flag: false, Data: "invalid options JSON: " + err.Error()}
	}

	results, err := a.CreateMultipleCloudInstancesTyped(optsList)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(results)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Multi-deploy complete: %d instances", len(optsList))
	return FlagResult{Flag: true, Data: string(data)}
}

// ScoreCloudRegions scores and ranks regions for deployment suitability.
func (a *App) ScoreCloudRegions(latenciesJSON string) FlagResult {
	log.Printf("[CloudBridge] ScoreCloudRegions called")

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	ctx, cancel := a.opCtx(cloudListOpTimeout)
	defer cancel()
	regions, err := provider.ListRegions(ctx)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var latencies map[string]float64
	if latenciesJSON != "" {
		if err := json.Unmarshal([]byte(latenciesJSON), &latencies); err != nil {
			latencies = make(map[string]float64)
		}
	} else {
		latencies = make(map[string]float64)
	}

	scores := cloud.ScoreRegions(regions, latencies)

	data, err := json.Marshal(scores)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	log.Printf("[CloudBridge] Scored %d regions", len(scores))
	return FlagResult{Flag: true, Data: string(data)}
}

// StartHealthMonitor starts periodic health checking for the active provider's nodes.
func (a *App) StartHealthMonitor() FlagResult {
	log.Printf("[CloudBridge] StartHealthMonitor called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	if a.HealthMonitor.IsRunning() {
		return FlagResult{Flag: true, Data: "already running"}
	}

	provider, err := a.CloudManager.GetActiveProvider()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	a.HealthMonitor.SetEventEmitter(func(event string, data ...interface{}) {
		runtime.EventsEmit(a.Ctx, event, data...)
	})

	a.HealthMonitor.Start(provider)
	return FlagResult{Flag: true, Data: "started"}
}

// StopHealthMonitor stops the health check loop.
func (a *App) StopHealthMonitor() FlagResult {
	log.Printf("[CloudBridge] StopHealthMonitor called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	a.HealthMonitor.Stop()
	return FlagResult{Flag: true, Data: "stopped"}
}

// GetHealthStatus returns the latest health check results.
func (a *App) GetHealthStatus() FlagResult {
	log.Printf("[CloudBridge] GetHealthStatus called")

	if a.HealthMonitor == nil {
		return FlagResult{Flag: false, Data: "health monitor not initialized"}
	}

	jsonStr, err := a.HealthMonitor.GetResultsJSON()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: jsonStr}
}
