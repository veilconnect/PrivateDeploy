package handlers

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"privatedeploy/api/models"
	"privatedeploy/bridge/cloud"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// opsFakeProvider extends fakeCloudProvider with an observable, configurable
// CreateInstance/DestroyInstance so async-operation behavior can be asserted.
type opsFakeProvider struct {
	fakeCloudProvider
	createCalls  atomic.Int32
	createErr    error
	createGate   chan struct{} // when non-nil, CreateInstance blocks until closed
	destroyCalls atomic.Int32
	destroyedIDs sync.Map
}

func (p *opsFakeProvider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	p.createCalls.Add(1)
	if p.createGate != nil {
		select {
		case <-p.createGate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if p.createErr != nil {
		return nil, p.createErr
	}
	return &cloud.Instance{
		ID:         "fake-instance-1",
		Provider:   p.Name(),
		Label:      opts.Label,
		Status:     "active",
		Region:     opts.Region,
		Plan:       opts.Plan,
		IPv4:       "198.51.100.7",
		SSPassword: "super-secret-node-password",
		Password:   "root-password",
	}, nil
}

func (p *opsFakeProvider) DestroyInstance(ctx context.Context, instanceID string) error {
	p.destroyCalls.Add(1)
	p.destroyedIDs.Store(instanceID, true)
	return nil
}

type opsTestEnv struct {
	router   *gin.Engine
	handler  *CloudHandler
	db       *gorm.DB
	provider *opsFakeProvider
}

func newOpsTestEnv(t *testing.T, opts ...CloudHandlerOption) *opsTestEnv {
	t.Helper()
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "ops.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.Exec("PRAGMA busy_timeout = 5000").Error; err != nil {
		t.Fatalf("set busy timeout: %v", err)
	}

	provider := &opsFakeProvider{fakeCloudProvider: fakeCloudProvider{name: "vultr", displayName: "Vultr"}}
	registry := cloud.NewRegistry()
	registry.Register("vultr", provider)

	manager := cloud.NewManager(context.Background(), registry)
	handler := NewCloudHandler(manager, db, "test-fp-secret", opts...)

	router := gin.New()
	router.POST("/cloud/instances", handler.CreateInstance)
	router.GET("/cloud/operations/:id", handler.GetOperation)
	router.DELETE("/cloud/instances/:id", handler.DestroyInstance)

	return &opsTestEnv{router: router, handler: handler, db: db, provider: provider}
}

func (env *opsTestEnv) postCreate(t *testing.T, body string, idemKey string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/cloud/instances", strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Content-Type", "application/json")
	if idemKey != "" {
		req.Header.Set("Idempotency-Key", idemKey)
	}
	rec := httptest.NewRecorder()
	env.router.ServeHTTP(rec, req)
	return rec
}

func decodeOperation(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode response: %v (%s)", err, body)
	}
	data, ok := payload["data"].(map[string]any)
	if !ok {
		t.Fatalf("expected data object, got %#v", payload)
	}
	op, ok := data["operation"].(map[string]any)
	if !ok {
		t.Fatalf("expected operation object, got %#v", data)
	}
	return op
}

// waitForOperationStatus polls the operations endpoint until the operation
// reaches a terminal status or the deadline passes.
func (env *opsTestEnv) waitForOperationStatus(t *testing.T, opID string, want string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var last map[string]any
	for time.Now().Before(deadline) {
		req := httptest.NewRequest(http.MethodGet, "/cloud/operations/"+opID, nil)
		req.RemoteAddr = "127.0.0.1:54321"
		rec := httptest.NewRecorder()
		env.router.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("get operation: status %d: %s", rec.Code, rec.Body.String())
		}
		last = decodeOperation(t, rec.Body.Bytes())
		if last["status"] == want {
			return last
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("operation %s never reached status %q, last: %#v", opID, want, last)
	return nil
}

const validCreateBody = `{"provider":"vultr","label":"node-1","region":"nrt","plan":"vc2-1c-1gb"}`

func TestCreateInstanceReturns202AndSucceedsWithoutSecrets(t *testing.T) {
	env := newOpsTestEnv(t)

	rec := env.postCreate(t, validCreateBody, "")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	op := decodeOperation(t, rec.Body.Bytes())
	if op["status"] != models.OpStatusPending && op["status"] != models.OpStatusRunning {
		t.Fatalf("expected pending/running status right after submit, got %#v", op["status"])
	}
	opID, _ := op["id"].(string)
	if opID == "" {
		t.Fatalf("expected operation id, got %#v", op)
	}
	if loc := rec.Header().Get("Location"); loc != "/api/v1/cloud/operations/"+opID {
		t.Fatalf("unexpected Location header %q", loc)
	}

	final := env.waitForOperationStatus(t, opID, models.OpStatusSucceeded)
	result, _ := final["result"].(string)
	if !strings.Contains(result, "fake-instance-1") {
		t.Fatalf("expected result to contain the instance id, got %q", result)
	}
	for _, secret := range []string{"super-secret-node-password", "root-password"} {
		if strings.Contains(result, secret) {
			t.Fatalf("operation result leaked a credential: %q", result)
		}
	}
	if env.provider.createCalls.Load() != 1 {
		t.Fatalf("expected exactly one provider create call, got %d", env.provider.createCalls.Load())
	}
}

func TestCreateInstanceRequiresExplicitProvider(t *testing.T) {
	env := newOpsTestEnv(t)

	rec := env.postCreate(t, `{"label":"node-1","region":"nrt","plan":"vc2-1c-1gb"}`, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without provider, got %d: %s", rec.Code, rec.Body.String())
	}
	if env.provider.createCalls.Load() != 0 {
		t.Fatal("provider must not be called when provider field is missing")
	}
}

func TestCreateInstanceRejectsUnknownAndExperimentalProviders(t *testing.T) {
	env := newOpsTestEnv(t)

	rec := env.postCreate(t, `{"provider":"digitalocean","label":"n","region":"r","plan":"p"}`, "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unregistered provider, got %d: %s", rec.Code, rec.Body.String())
	}

	rec = env.postCreate(t, `{"provider":"oracle","label":"n","region":"r","plan":"p"}`, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for experimental provider, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCreateInstanceIdempotencyKeyDeduplicates(t *testing.T) {
	env := newOpsTestEnv(t)

	first := env.postCreate(t, validCreateBody, "idem-abc")
	if first.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", first.Code, first.Body.String())
	}
	firstOp := decodeOperation(t, first.Body.Bytes())
	firstID, _ := firstOp["id"].(string)

	env.waitForOperationStatus(t, firstID, models.OpStatusSucceeded)

	second := env.postCreate(t, validCreateBody, "idem-abc")
	if second.Code != http.StatusAccepted {
		t.Fatalf("expected 202 on retry, got %d: %s", second.Code, second.Body.String())
	}
	secondOp := decodeOperation(t, second.Body.Bytes())
	if secondOp["id"] != firstID {
		t.Fatalf("expected retry to return the original operation %q, got %#v", firstID, secondOp["id"])
	}
	if secondOp["status"] != models.OpStatusSucceeded {
		t.Fatalf("expected retry to report the completed status, got %#v", secondOp["status"])
	}
	if env.provider.createCalls.Load() != 1 {
		t.Fatalf("expected exactly one provider create call, got %d", env.provider.createCalls.Load())
	}
}

func TestCreateInstanceConcurrentIdempotentRequestsCreateOnce(t *testing.T) {
	env := newOpsTestEnv(t)

	const concurrency = 8
	ids := make([]string, concurrency)
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			rec := env.postCreate(t, validCreateBody, "idem-race")
			if rec.Code != http.StatusAccepted {
				t.Errorf("slot %d: expected 202, got %d: %s", slot, rec.Code, rec.Body.String())
				return
			}
			op := decodeOperation(t, rec.Body.Bytes())
			ids[slot], _ = op["id"].(string)
		}(i)
	}
	wg.Wait()

	for i := 1; i < concurrency; i++ {
		if ids[i] == "" || ids[i] != ids[0] {
			t.Fatalf("expected all concurrent submissions to share one operation, got %v", ids)
		}
	}

	env.waitForOperationStatus(t, ids[0], models.OpStatusSucceeded)
	if env.provider.createCalls.Load() != 1 {
		t.Fatalf("expected exactly one provider create call, got %d", env.provider.createCalls.Load())
	}
}

func TestCreateInstanceFailureStoresSanitizedError(t *testing.T) {
	env := newOpsTestEnv(t)
	env.provider.createErr = fmt.Errorf("provider exploded: %s", strings.Repeat("x", 2000))

	rec := env.postCreate(t, validCreateBody, "")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	opID, _ := decodeOperation(t, rec.Body.Bytes())["id"].(string)

	final := env.waitForOperationStatus(t, opID, models.OpStatusFailed)
	errMsg, _ := final["error"].(string)
	if errMsg == "" {
		t.Fatal("expected a stored error message")
	}
	if !strings.Contains(errMsg, "provider exploded") {
		t.Fatalf("expected the provider error to be surfaced, got %q", errMsg)
	}
	if len(errMsg) > 600 {
		t.Fatalf("expected the stored error to be truncated, got %d bytes", len(errMsg))
	}
}

func TestInterruptedOperationsFailOnRestart(t *testing.T) {
	env := newOpsTestEnv(t)

	stale := models.CloudOperation{
		ID:       "op_stale",
		Type:     models.OpTypeCreateInstance,
		Provider: "vultr",
		Status:   models.OpStatusRunning,
	}
	if err := env.db.Create(&stale).Error; err != nil {
		t.Fatalf("seed stale operation: %v", err)
	}

	// Simulate a process restart: a fresh handler over the same database.
	manager := cloud.NewManager(context.Background(), cloud.NewRegistry())
	NewCloudHandler(manager, env.db, "test-fp-secret")

	var reloaded models.CloudOperation
	if err := env.db.First(&reloaded, "id = ?", "op_stale").Error; err != nil {
		t.Fatalf("reload operation: %v", err)
	}
	if reloaded.Status != models.OpStatusFailed {
		t.Fatalf("expected interrupted operation to be failed on restart, got %q", reloaded.Status)
	}
	if !strings.Contains(reloaded.Error, "restart") {
		t.Fatalf("expected restart explanation in error, got %q", reloaded.Error)
	}
}

func TestDestroyInstanceRequiresExplicitProvider(t *testing.T) {
	env := newOpsTestEnv(t)

	req := httptest.NewRequest(http.MethodDelete, "/cloud/instances/inst-1", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	env.router.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without provider, got %d: %s", rec.Code, rec.Body.String())
	}
	if env.provider.destroyCalls.Load() != 0 {
		t.Fatal("provider must not be called when provider param is missing")
	}

	req = httptest.NewRequest(http.MethodDelete, "/cloud/instances/inst-1?provider=vultr", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec = httptest.NewRecorder()
	env.router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 with explicit provider, got %d: %s", rec.Code, rec.Body.String())
	}
	if _, ok := env.provider.destroyedIDs.Load("inst-1"); !ok {
		t.Fatal("expected destroy to reach the requested provider with the instance id")
	}
}

func TestDestroyInstanceUsesRequestedProviderNotActive(t *testing.T) {
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "ops.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}

	vultrProvider := &opsFakeProvider{fakeCloudProvider: fakeCloudProvider{name: "vultr", displayName: "Vultr"}}
	doProvider := &opsFakeProvider{fakeCloudProvider: fakeCloudProvider{name: "digitalocean", displayName: "DigitalOcean"}}
	registry := cloud.NewRegistry()
	registry.Register("vultr", vultrProvider)
	registry.Register("digitalocean", doProvider)

	manager := cloud.NewManager(context.Background(), registry)
	// The globally active provider deliberately differs from the request.
	if err := manager.SetActiveProvider("vultr"); err != nil {
		t.Fatalf("set active provider: %v", err)
	}

	handler := NewCloudHandler(manager, db, "test-fp-secret")
	router := gin.New()
	router.DELETE("/cloud/instances/:id", handler.DestroyInstance)

	req := httptest.NewRequest(http.MethodDelete, "/cloud/instances/inst-9?provider=digitalocean", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if doProvider.destroyCalls.Load() != 1 {
		t.Fatal("expected destroy to hit the explicitly requested provider")
	}
	if vultrProvider.destroyCalls.Load() != 0 {
		t.Fatal("destroy must not fall back to the active provider")
	}
}

// syncBuffer is a goroutine-safe log sink: the background create goroutine
// writes to it while the test goroutine reads it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestCreateInstanceIdempotencyKeyConflictsOnDifferentRequest(t *testing.T) {
	env := newOpsTestEnv(t)

	first := env.postCreate(t, validCreateBody, "idem-fp")
	if first.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", first.Code, first.Body.String())
	}
	firstID, _ := decodeOperation(t, first.Body.Bytes())["id"].(string)
	env.waitForOperationStatus(t, firstID, models.OpStatusSucceeded)

	// Same key, different region → 409.
	conflict := env.postCreate(t, `{"provider":"vultr","label":"node-1","region":"fra","plan":"vc2-1c-1gb"}`, "idem-fp")
	if conflict.Code != http.StatusConflict {
		t.Fatalf("expected 409 for a reused key with a different request, got %d: %s", conflict.Code, conflict.Body.String())
	}
	if !strings.Contains(conflict.Body.String(), models.ErrIdempotencyConflict) {
		t.Fatalf("expected %s error code, got %s", models.ErrIdempotencyConflict, conflict.Body.String())
	}

	// Same key, same primary fields but different Extra → 409 too.
	conflict = env.postCreate(t, `{"provider":"vultr","label":"node-1","region":"nrt","plan":"vc2-1c-1gb","extra":{"password":"x"}}`, "idem-fp")
	if conflict.Code != http.StatusConflict {
		t.Fatalf("expected 409 for a reused key with different Extra, got %d: %s", conflict.Code, conflict.Body.String())
	}

	// Whitespace is preserved by providers, so the same key with different
	// raw values must conflict rather than suppress a behaviorally different
	// request.
	replay := env.postCreate(t, `{"provider":"vultr","label":" node-1 ","region":"nrt","plan":"vc2-1c-1gb"}`, "idem-fp")
	if replay.Code != http.StatusConflict {
		t.Fatalf("expected 409 for a whitespace-different request, got %d: %s", replay.Code, replay.Body.String())
	}

	if env.provider.createCalls.Load() != 1 {
		t.Fatalf("expected exactly one provider create call, got %d", env.provider.createCalls.Load())
	}

	// The stored fingerprint is an opaque hex HMAC-SHA256.
	var op models.CloudOperation
	if err := env.db.First(&op, "id = ?", firstID).Error; err != nil {
		t.Fatalf("reload operation: %v", err)
	}
	if len(op.RequestFingerprint) != 64 {
		t.Fatalf("expected a 64-char hex fingerprint, got %q", op.RequestFingerprint)
	}
	if _, err := hex.DecodeString(op.RequestFingerprint); err != nil {
		t.Fatalf("expected a hex fingerprint, got %q: %v", op.RequestFingerprint, err)
	}
}

func TestUpdateOperationRetriesTerminalUpdateUntilExhausted(t *testing.T) {
	env := newOpsTestEnv(t)
	env.handler.terminalRetryBackoff = time.Millisecond

	var attempts atomic.Int32
	env.handler.onTerminalUpdateRetry = func(attempt int, err error) {
		attempts.Add(1)
	}

	op := models.CloudOperation{ID: "op_retry", Type: models.OpTypeCreateInstance, Provider: "vultr", Status: models.OpStatusRunning}
	if err := env.db.Create(&op).Error; err != nil {
		t.Fatalf("seed operation: %v", err)
	}

	// Kill the underlying connection so every update attempt fails.
	sqlDB, err := env.db.DB()
	if err != nil {
		t.Fatalf("sql db: %v", err)
	}
	sqlDB.Close()

	logBuf := &syncBuffer{}
	log.SetOutput(logBuf)
	defer log.SetOutput(os.Stderr)

	env.handler.updateOperation("op_retry", map[string]any{
		"status": models.OpStatusFailed,
		"error":  "boom",
	})

	if got := attempts.Load(); got != 5 {
		t.Fatalf("expected 5 terminal update attempts, got %d", got)
	}
	if logs := logBuf.String(); !strings.Contains(logs, "after 5 attempt(s)") {
		t.Fatalf("expected a final give-up log after 5 attempts, got:\n%s", logs)
	}
}

func TestUpdateOperationTerminalRetryRecoversAfterTransientFailure(t *testing.T) {
	env := newOpsTestEnv(t)
	env.handler.terminalRetryBackoff = time.Millisecond

	op := models.CloudOperation{ID: "op_transient", Type: models.OpTypeCreateInstance, Provider: "vultr", Status: models.OpStatusRunning}
	if err := env.db.Create(&op).Error; err != nil {
		t.Fatalf("seed operation: %v", err)
	}

	// Make the first attempt fail by hiding the table, then restore it from
	// the retry hook so the second attempt succeeds.
	if err := env.db.Exec("ALTER TABLE cloud_operations RENAME TO cloud_operations_hidden").Error; err != nil {
		t.Fatalf("hide table: %v", err)
	}
	var attempts atomic.Int32
	env.handler.onTerminalUpdateRetry = func(attempt int, err error) {
		if attempts.Add(1) == 1 {
			if rerr := env.db.Exec("ALTER TABLE cloud_operations_hidden RENAME TO cloud_operations").Error; rerr != nil {
				t.Errorf("restore table: %v", rerr)
			}
		}
	}

	env.handler.updateOperation("op_transient", map[string]any{
		"status": models.OpStatusSucceeded,
		"result": "{}",
	})

	if got := attempts.Load(); got != 1 {
		t.Fatalf("expected exactly one failed attempt before recovery, got %d", got)
	}
	var reloaded models.CloudOperation
	if err := env.db.First(&reloaded, "id = ?", "op_transient").Error; err != nil {
		t.Fatalf("reload operation: %v", err)
	}
	if reloaded.Status != models.OpStatusSucceeded {
		t.Fatalf("expected the retried terminal update to land, got status %q", reloaded.Status)
	}
}

func TestOperationFailureRedactsSecretsEverywhere(t *testing.T) {
	env := newOpsTestEnv(t)
	const sentinel = "SENTINEL_SECRET_9f3"
	env.provider.createErr = fmt.Errorf(
		"deploy failed: ssh auth password=%s rejected; Authorization: Bearer tok.abc-123; api_key=AK99ZZ; key material:\n-----BEGIN RSA "+
			"PRIVATE KEY-----\nMIIfakekeymaterial\n-----END RSA PRIVATE KEY-----",
		sentinel)

	logBuf := &syncBuffer{}
	log.SetOutput(logBuf)
	defer log.SetOutput(os.Stderr)

	body := fmt.Sprintf(`{"provider":"vultr","label":"n1","region":"nrt","plan":"p1","extra":{"password":%q}}`, sentinel)
	rec := env.postCreate(t, body, "")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	opID, _ := decodeOperation(t, rec.Body.Bytes())["id"].(string)

	final := env.waitForOperationStatus(t, opID, models.OpStatusFailed)
	apiErr, _ := final["error"].(string)

	var row models.CloudOperation
	if err := env.db.First(&row, "id = ?", opID).Error; err != nil {
		t.Fatalf("reload operation row: %v", err)
	}
	logs := logBuf.String()

	for name, text := range map[string]string{
		"GET /operations/:id response": apiErr,
		"database row error":           row.Error,
		"captured log output":          logs,
	} {
		for _, leaked := range []string{sentinel, "tok.abc-123", "AK99ZZ", "MIIfakekeymaterial"} {
			if strings.Contains(text, leaked) {
				t.Fatalf("%s leaked secret %q:\n%s", name, leaked, text)
			}
		}
	}
	if !strings.Contains(apiErr, "[REDACTED]") {
		t.Fatalf("expected redaction markers in the stored error, got %q", apiErr)
	}
	if !strings.Contains(apiErr, "deploy failed") {
		t.Fatalf("expected the non-secret part of the error to survive, got %q", apiErr)
	}

	// The persisted request metadata must not carry the secret either.
	if strings.Contains(row.RequestSummary, sentinel) {
		t.Fatalf("request summary leaked the secret: %q", row.RequestSummary)
	}
	if strings.Contains(row.RequestFingerprint, sentinel) {
		t.Fatalf("request fingerprint leaked the secret: %q", row.RequestFingerprint)
	}
}

func TestCreateInstanceConcurrencyLimit(t *testing.T) {
	env := newOpsTestEnv(t, WithMaxConcurrentCreates(2))
	env.provider.createGate = make(chan struct{})

	bodyA := `{"provider":"vultr","label":"a","region":"nrt","plan":"p"}`
	bodyB := `{"provider":"vultr","label":"b","region":"nrt","plan":"p"}`
	bodyC := `{"provider":"vultr","label":"c","region":"nrt","plan":"p"}`

	recA := env.postCreate(t, bodyA, "key-a")
	if recA.Code != http.StatusAccepted {
		t.Fatalf("first create: expected 202, got %d: %s", recA.Code, recA.Body.String())
	}
	opA, _ := decodeOperation(t, recA.Body.Bytes())["id"].(string)

	recB := env.postCreate(t, bodyB, "key-b")
	if recB.Code != http.StatusAccepted {
		t.Fatalf("second create: expected 202, got %d: %s", recB.Code, recB.Body.String())
	}
	opB, _ := decodeOperation(t, recB.Body.Bytes())["id"].(string)

	// Both slots busy: a new create is rejected with 429.
	recC := env.postCreate(t, bodyC, "key-c")
	if recC.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 at capacity, got %d: %s", recC.Code, recC.Body.String())
	}
	if !strings.Contains(recC.Body.String(), models.ErrTooManyOperations) {
		t.Fatalf("expected %s error code, got %s", models.ErrTooManyOperations, recC.Body.String())
	}

	// An idempotent replay of an in-flight operation still succeeds at capacity.
	replay := env.postCreate(t, bodyA, "key-a")
	if replay.Code != http.StatusAccepted {
		t.Fatalf("expected 202 for an idempotent replay at capacity, got %d: %s", replay.Code, replay.Body.String())
	}
	if id, _ := decodeOperation(t, replay.Body.Bytes())["id"].(string); id != opA {
		t.Fatalf("expected replay to return operation %q, got %q", opA, id)
	}

	// Unblock the provider; both operations finish and free their slots.
	close(env.provider.createGate)
	env.waitForOperationStatus(t, opA, models.OpStatusSucceeded)
	env.waitForOperationStatus(t, opB, models.OpStatusSucceeded)

	// Slot release races the final status update by a hair, so poll briefly.
	deadline := time.Now().Add(3 * time.Second)
	for {
		recD := env.postCreate(t, bodyC, "key-c")
		if recD.Code == http.StatusAccepted {
			break
		}
		if recD.Code != http.StatusTooManyRequests {
			t.Fatalf("expected 202 or 429 while slots free up, got %d: %s", recD.Code, recD.Body.String())
		}
		if time.Now().After(deadline) {
			t.Fatal("creates never recovered after the concurrency slots were released")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestConcurrentSameIdempotencyKeyNeverGetsCapacity429(t *testing.T) {
	env := newOpsTestEnv(t, WithMaxConcurrentCreates(1))
	env.provider.createGate = make(chan struct{})
	const body = `{"provider":"vultr","label":"same","region":"nrt","plan":"p"}`

	start := make(chan struct{})
	results := make(chan *httptest.ResponseRecorder, 2)
	post := func() {
		<-start
		req := httptest.NewRequest(http.MethodPost, "/cloud/instances", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Idempotency-Key", "same-key-race")
		rec := httptest.NewRecorder()
		env.router.ServeHTTP(rec, req)
		results <- rec
	}
	go post()
	go post()
	close(start)

	first, second := <-results, <-results
	for i, rec := range []*httptest.ResponseRecorder{first, second} {
		if rec.Code != http.StatusAccepted {
			t.Fatalf("request %d: expected 202, got %d: %s", i+1, rec.Code, rec.Body.String())
		}
	}
	firstID, _ := decodeOperation(t, first.Body.Bytes())["id"].(string)
	secondID, _ := decodeOperation(t, second.Body.Bytes())["id"].(string)
	if firstID != secondID {
		t.Fatalf("same key created different operations: %q vs %q", firstID, secondID)
	}
	close(env.provider.createGate)
	env.waitForOperationStatus(t, firstID, models.OpStatusSucceeded)
	if env.provider.createCalls.Load() != 1 {
		t.Fatalf("expected one provider create, got %d", env.provider.createCalls.Load())
	}
}
