package cloud

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud/persistence"
)

// Terminal create outcomes remain available long enough for a restarted UI to
// recover the original result. Non-terminal submissions are retained longer:
// an old submitted record is still evidence that retrying the POST is unsafe.
const (
	CreateOperationTerminalRetention = 7 * 24 * time.Hour
	CreateOperationPendingRetention  = 30 * 24 * time.Hour
)

type CreateOperationState string

const (
	CreateOperationPending     CreateOperationState = "pending"
	CreateOperationPrepared    CreateOperationState = "prepared"
	CreateOperationSubmitted   CreateOperationState = "submitted"
	CreateOperationReconciling CreateOperationState = "reconciling"
	CreateOperationSucceeded   CreateOperationState = "succeeded"
	CreateOperationFailed      CreateOperationState = "failed"
)

// CreateOperationRecord is the durable, encrypted source of truth for a
// billable create. ProviderData contains the credentials generated before the
// POST and is intentionally opaque to the bridge.
type CreateOperationRecord struct {
	Version            int                   `json:"version"`
	OperationID        string                `json:"operationId"`
	Provider           string                `json:"provider"`
	OperationTag       string                `json:"operationTag"`
	OptionsFingerprint string                `json:"optionsFingerprint"`
	Options            CreateInstanceOptions `json:"options"`
	State              CreateOperationState  `json:"state"`
	ProviderData       json.RawMessage       `json:"providerData,omitempty"`
	RemoteInstanceID   string                `json:"remoteInstanceId,omitempty"`
	Instance           *Instance             `json:"instance,omitempty"`
	LastError          string                `json:"lastError,omitempty"`
	CreatedAt          time.Time             `json:"createdAt"`
	UpdatedAt          time.Time             `json:"updatedAt"`
	ExpiresAt          time.Time             `json:"expiresAt"`
}

var createOperationJournalMu sync.Mutex

// CreateOperationTag returns a provider-safe marker without disclosing the
// client operation ID. Its 128-bit hash suffix makes an accidental collision
// infeasible while fitting both Vultr and DigitalOcean tag constraints.
func CreateOperationTag(provider, operationID string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(provider) + "\x00" + strings.TrimSpace(operationID)))
	return "privatedeploy-op-" + hex.EncodeToString(sum[:16])
}

func CreateOperationJournalPath(basePath, provider, operationID string) string {
	tag := CreateOperationTag(provider, operationID)
	providerPart := strings.ToLower(strings.TrimSpace(provider))
	if providerPart == "" {
		providerPart = "unknown"
	}
	for _, disallowed := range []string{"/", "\\", "..", "\x00"} {
		providerPart = strings.ReplaceAll(providerPart, disallowed, "-")
	}
	return filepath.Join(basePath, "data", "cloud", "operations", providerPart+"-"+strings.TrimPrefix(tag, "privatedeploy-op-")+".pdop")
}

func CreateOperationJournalDir(basePath string) string {
	return filepath.Join(basePath, "data", "cloud", "operations")
}

// ListCreateOperations returns durable records for one provider. Corrupt
// records are reported rather than skipped so billing evidence can never
// silently disappear from recovery.
func ListCreateOperations(basePath, provider string) ([]CreateOperationRecord, error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()
	dir := CreateOperationJournalDir(basePath)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	records := make([]CreateOperationRecord, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pdop") {
			continue
		}
		record, err := readCreateOperationUnlocked(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		if record.Provider == strings.TrimSpace(provider) {
			records = append(records, record)
		}
	}
	return records, nil
}

// ListPendingCreateOperations returns every non-terminal durable create,
// independently of the currently selected provider. The renderer uses this
// safe-to-read source of truth after a restart; callers must still avoid
// returning the full records over an IPC boundary because Options.Extra and
// ProviderData can contain credentials.
func ListPendingCreateOperations(basePath string) ([]CreateOperationRecord, error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()
	dir := CreateOperationJournalDir(basePath)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	records := make([]CreateOperationRecord, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pdop") {
			continue
		}
		record, err := readCreateOperationUnlocked(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		if record.State == CreateOperationSucceeded || record.State == CreateOperationFailed {
			continue
		}
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].CreatedAt.Equal(records[j].CreatedAt) {
			return records[i].OperationID < records[j].OperationID
		}
		return records[i].CreatedAt.Before(records[j].CreatedAt)
	})
	return records, nil
}

// FindCreateOperation resolves an operation independently of the currently
// selected provider. Operation IDs are expected to be globally unique; two
// provider records with the same ID fail closed rather than returning the
// wrong billed resource.
func FindCreateOperation(basePath, operationID string) (CreateOperationRecord, error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()
	dir := CreateOperationJournalDir(basePath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return CreateOperationRecord{}, err
	}
	operationID = strings.TrimSpace(operationID)
	var match *CreateOperationRecord
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pdop") {
			continue
		}
		record, err := readCreateOperationUnlocked(filepath.Join(dir, entry.Name()))
		if err != nil {
			return CreateOperationRecord{}, err
		}
		if record.OperationID != operationID {
			continue
		}
		if match != nil {
			return CreateOperationRecord{}, fmt.Errorf("cloud operation ID %q belongs to multiple providers", operationID)
		}
		copy := record
		match = &copy
	}
	if match == nil {
		return CreateOperationRecord{}, os.ErrNotExist
	}
	return *match, nil
}

func CreateOperationOptionsFingerprint(provider string, opts CreateInstanceOptions) (string, error) {
	opts.OperationJournalPath = ""
	payload, err := json.Marshal(struct {
		Provider string                `json:"provider"`
		Options  CreateInstanceOptions `json:"options"`
	}{Provider: strings.TrimSpace(provider), Options: opts})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:]), nil
}

// PrepareCreateOperation atomically establishes the first durable operation
// record. created=false means another process already owns or completed this
// exact operation and the returned record must be reconciled, never re-POSTed.
func PrepareCreateOperation(path, provider string, opts CreateInstanceOptions) (record CreateOperationRecord, created bool, err error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()

	if strings.TrimSpace(opts.OperationID) == "" {
		return record, false, errors.New("cloud operation ID is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return record, false, fmt.Errorf("create cloud operation directory: %w", err)
	}
	_ = pruneCreateOperationsLocked(filepath.Dir(path), time.Now().UTC())

	fingerprint, err := CreateOperationOptionsFingerprint(provider, opts)
	if err != nil {
		return record, false, fmt.Errorf("fingerprint cloud create options: %w", err)
	}
	now := time.Now().UTC()
	storedOptions := opts
	storedOptions.OperationJournalPath = ""
	record = CreateOperationRecord{
		Version:            1,
		OperationID:        strings.TrimSpace(opts.OperationID),
		Provider:           strings.TrimSpace(provider),
		OperationTag:       CreateOperationTag(provider, opts.OperationID),
		OptionsFingerprint: fingerprint,
		Options:            storedOptions,
		State:              CreateOperationPending,
		CreatedAt:          now,
		UpdatedAt:          now,
		ExpiresAt:          now.Add(CreateOperationPendingRetention),
	}
	blob, err := EncodeRecords(record)
	if err != nil {
		return CreateOperationRecord{}, false, fmt.Errorf("encrypt cloud operation: %w", err)
	}
	if err := persistence.CreatePrivateFileExclusive(path, blob); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return CreateOperationRecord{}, false, fmt.Errorf("persist cloud operation before submit: %w", err)
		}
		existing, loadErr := readCreateOperationUnlocked(path)
		if loadErr != nil {
			return CreateOperationRecord{}, false, loadErr
		}
		if err := validateCreateOperation(existing, provider, opts, fingerprint); err != nil {
			return CreateOperationRecord{}, false, err
		}
		return existing, false, nil
	}
	return record, true, nil
}

func ReadCreateOperation(path string) (CreateOperationRecord, error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()
	return readCreateOperationUnlocked(path)
}

func readCreateOperationUnlocked(path string) (CreateOperationRecord, error) {
	var record CreateOperationRecord
	blob, err := os.ReadFile(path)
	if err != nil {
		return record, err
	}
	if err := DecodeRecords(blob, &record); err != nil {
		return record, fmt.Errorf("decode cloud operation journal: %w", err)
	}
	if record.Version != 1 || strings.TrimSpace(record.OperationID) == "" || strings.TrimSpace(record.Provider) == "" {
		return record, errors.New("invalid cloud operation journal record")
	}
	return record, nil
}

func validateCreateOperation(record CreateOperationRecord, provider string, opts CreateInstanceOptions, fingerprint string) error {
	if record.OperationID != strings.TrimSpace(opts.OperationID) || record.Provider != strings.TrimSpace(provider) {
		return errors.New("cloud operation ID is already owned by another provider operation")
	}
	if record.OptionsFingerprint != fingerprint {
		return errors.New("cloud operation ID was reused with different create options")
	}
	if record.OperationTag != CreateOperationTag(provider, opts.OperationID) {
		return errors.New("cloud operation journal marker does not match its operation ID")
	}
	return nil
}

// UpdateCreateOperation performs an encrypted atomic update. The bridge holds
// a cross-process file lock for the whole create/reconcile flow; this mutex
// additionally serializes status readers and provider updates in-process.
func UpdateCreateOperation(path string, update func(*CreateOperationRecord) error) (CreateOperationRecord, error) {
	createOperationJournalMu.Lock()
	defer createOperationJournalMu.Unlock()

	record, err := readCreateOperationUnlocked(path)
	if err != nil {
		return record, err
	}
	if err := update(&record); err != nil {
		return record, err
	}
	record.UpdatedAt = time.Now().UTC()
	if record.State == CreateOperationSucceeded || record.State == CreateOperationFailed {
		record.ExpiresAt = record.UpdatedAt.Add(CreateOperationTerminalRetention)
	} else {
		record.ExpiresAt = record.UpdatedAt.Add(CreateOperationPendingRetention)
	}
	blob, err := EncodeRecords(record)
	if err != nil {
		return record, fmt.Errorf("encrypt cloud operation update: %w", err)
	}
	if err := persistence.WritePrivateFileAtomic(path, blob); err != nil {
		return record, fmt.Errorf("persist cloud operation update: %w", err)
	}
	return record, nil
}

func StoreCreateOperationProviderData(path string, state CreateOperationState, value any) error {
	if state != CreateOperationPrepared && state != CreateOperationSubmitted && state != CreateOperationReconciling {
		return fmt.Errorf("invalid provider-data operation state %q", state)
	}
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		record.ProviderData = append(record.ProviderData[:0], payload...)
		record.State = state
		return nil
	})
	return err
}

func LoadCreateOperationProviderData(path string, value any) (CreateOperationRecord, error) {
	record, err := ReadCreateOperation(path)
	if err != nil {
		return record, err
	}
	if len(record.ProviderData) == 0 {
		return record, errors.New("cloud create operation was not prepared before process exit")
	}
	if err := json.Unmarshal(record.ProviderData, value); err != nil {
		return record, fmt.Errorf("decode cloud create provider data: %w", err)
	}
	return record, nil
}

func MarkCreateOperationSubmitted(path string) error {
	_, err := UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		if len(record.ProviderData) == 0 {
			return errors.New("refusing to submit cloud create before credentials are journaled")
		}
		record.State = CreateOperationSubmitted
		record.LastError = ""
		return nil
	})
	return err
}

func MarkCreateOperationRemote(path, remoteInstanceID string) error {
	_, err := UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		record.RemoteInstanceID = strings.TrimSpace(remoteInstanceID)
		return nil
	})
	return err
}

func MarkCreateOperationReconciling(path string, reconcileErr error) error {
	_, err := UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		record.State = CreateOperationReconciling
		if reconcileErr != nil {
			record.LastError = createOperationErrorMessage(reconcileErr, &record.Options)
		}
		return nil
	})
	return err
}

func CompleteCreateOperation(path string, instance *Instance) error {
	_, err := UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		record.State = CreateOperationSucceeded
		record.LastError = ""
		record.Instance = cloneJournalInstance(instance)
		if instance != nil && record.RemoteInstanceID == "" {
			record.RemoteInstanceID = instance.ID
		}
		return nil
	})
	return err
}

func FailCreateOperation(path string, createErr error) error {
	_, err := UpdateCreateOperation(path, func(record *CreateOperationRecord) error {
		record.State = CreateOperationFailed
		record.Instance = nil
		if createErr == nil {
			record.LastError = "cloud create failed"
		} else {
			record.LastError = createOperationErrorMessage(createErr, &record.Options)
		}
		return nil
	})
	return err
}

func cloneJournalInstance(instance *Instance) *Instance {
	if instance == nil {
		return nil
	}
	clone := *instance
	return &clone
}

func pruneCreateOperationsLocked(dir string, now time.Time) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pdop") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		record, err := readCreateOperationUnlocked(path)
		if err != nil || record.ExpiresAt.IsZero() || now.Before(record.ExpiresAt) {
			continue
		}
		// Submitted/reconciling records are evidence against another POST. Keep
		// them even beyond the normal window; only explicit terminal outcomes
		// are automatically collected.
		if record.State == CreateOperationSucceeded || record.State == CreateOperationFailed {
			_ = os.Remove(path)
		}
	}
	return nil
}
