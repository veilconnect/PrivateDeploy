package handlers

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"privatedeploy/api/models"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// createInstanceTimeout bounds a background instance-creation operation.
// Providers wait for the node to become reachable, so this is generous.
const createInstanceTimeout = 30 * time.Minute

// defaultMaxConcurrentCreates bounds how many background instance-creation
// operations may run at once. Each one holds a goroutine, provider API quota
// and eventually a billable VPS, so an unbounded queue is never what the
// operator wants. Requests beyond the cap get 429 and should be retried.
const defaultMaxConcurrentCreates = 8

// Terminal operation updates (succeeded/failed) must not be lost to a
// transient database error, or the operation would appear "running" forever.
const (
	terminalUpdateMaxAttempts   = 5
	defaultTerminalRetryBackoff = 100 * time.Millisecond
)

// CloudHandler handles cloud-related requests
type CloudHandler struct {
	manager *cloud.Manager
	db      *gorm.DB

	// fingerprintKey keys the HMAC-SHA256 request fingerprints that bind an
	// Idempotency-Key to the request payload that first used it.
	fingerprintKey []byte

	// createSem is a counting semaphore bounding concurrent background create
	// operations. A slot is acquired in CreateInstance (after the idempotency
	// lookup, so replays always succeed even at capacity) and released when
	// the background operation finishes.
	createSem chan struct{}
	// idempotencyInFlight serializes only the short lookup/insert window for
	// identical keys. A duplicate waits for the first operation row to exist
	// instead of spuriously receiving 429 while that first request owns a
	// create slot but has not committed its row yet.
	idempotencyMu       sync.Mutex
	idempotencyInFlight map[string]chan struct{}

	// terminalRetryBackoff is the base backoff between terminal-update retry
	// attempts; tests shrink it.
	terminalRetryBackoff time.Duration
	// onTerminalUpdateRetry, when set (tests only), is invoked after each
	// failed terminal-update attempt.
	onTerminalUpdateRetry func(attempt int, err error)
}

// CloudHandlerOption customizes a CloudHandler.
type CloudHandlerOption func(*CloudHandler)

// WithMaxConcurrentCreates overrides the default concurrent background create
// cap (used by tests; production keeps defaultMaxConcurrentCreates).
func WithMaxConcurrentCreates(n int) CloudHandlerOption {
	return func(h *CloudHandler) {
		if n > 0 {
			h.createSem = make(chan struct{}, n)
		}
	}
}

// NewCloudHandler creates a new CloudHandler. db backs the persistent cloud
// operation log; it may be nil in contexts that only serve read endpoints.
//
// fingerprintSecret is the dedicated persistent idempotency key loaded by the
// server config; it is intentionally independent of the API auth token. When
// it is empty a random in-process key is generated instead — fingerprints then
// do NOT survive a restart: replaying a pre-restart Idempotency-Key after a
// restart is answered with 409 (fingerprint mismatch) rather than replaying
// the stored operation.
func NewCloudHandler(manager *cloud.Manager, db *gorm.DB, fingerprintSecret string, opts ...CloudHandlerOption) *CloudHandler {
	key := []byte(strings.TrimSpace(fingerprintSecret))
	if len(key) == 0 {
		buf := make([]byte, 32)
		if _, err := rand.Read(buf); err != nil {
			// Last-resort fallback; still per-process and unpredictable enough
			// for a non-cryptographic uniqueness check.
			buf = []byte(time.Now().UTC().Format(time.RFC3339Nano))
		}
		key = buf
	}

	h := &CloudHandler{
		manager:              manager,
		db:                   db,
		fingerprintKey:       key,
		createSem:            make(chan struct{}, defaultMaxConcurrentCreates),
		idempotencyInFlight:  make(map[string]chan struct{}),
		terminalRetryBackoff: defaultTerminalRetryBackoff,
	}
	for _, opt := range opts {
		opt(h)
	}
	if db != nil {
		if err := db.AutoMigrate(&models.CloudOperation{}); err != nil {
			log.Printf("[CloudHandler] ERROR: failed to migrate cloud operations table: %v", err)
		} else {
			h.failInterruptedOperations()
		}
	}
	return h
}

func (h *CloudHandler) beginIdempotencyInsert(key string) (bool, <-chan struct{}) {
	h.idempotencyMu.Lock()
	defer h.idempotencyMu.Unlock()
	if done, exists := h.idempotencyInFlight[key]; exists {
		return false, done
	}
	done := make(chan struct{})
	h.idempotencyInFlight[key] = done
	return true, done
}

func (h *CloudHandler) finishIdempotencyInsert(key string) {
	h.idempotencyMu.Lock()
	done := h.idempotencyInFlight[key]
	delete(h.idempotencyInFlight, key)
	if done != nil {
		close(done)
	}
	h.idempotencyMu.Unlock()
}

// failInterruptedOperations marks operations left pending/running by a
// previous process as failed, so a restart never silently loses a known
// operation or leaves it "running" forever.
func (h *CloudHandler) failInterruptedOperations() {
	result := h.db.Model(&models.CloudOperation{}).
		Where("status IN ?", []string{models.OpStatusPending, models.OpStatusRunning}).
		Updates(map[string]any{
			"status": models.OpStatusFailed,
			"error":  "operation interrupted by an API server restart; check the provider console for the instance state before retrying",
		})
	if result.Error != nil {
		log.Printf("[CloudHandler] ERROR: failed to fail interrupted operations: %v", result.Error)
	} else if result.RowsAffected > 0 {
		log.Printf("[CloudHandler] Marked %d interrupted cloud operation(s) as failed", result.RowsAffected)
	}
}

// requestProvider resolves the explicitly requested provider from the shared
// registry. Mutating endpoints must not depend on the global activeProvider:
// with multiple clients it is ambiguous which provider a create/delete targets.
func (h *CloudHandler) requestProvider(c *gin.Context, name string) (cloud.CloudProvider, bool) {
	name = strings.TrimSpace(name)
	if name == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"provider is required for this operation",
		))
		return nil, false
	}
	return h.namedProvider(c, name)
}

// readProvider resolves the provider for read-style endpoints. An explicit,
// non-empty name (from ?provider= or a request body) wins; when it is empty
// the shared active provider is used so older clients keep working.
func (h *CloudHandler) readProvider(c *gin.Context, name string) (cloud.CloudProvider, bool) {
	name = strings.TrimSpace(name)
	if name == "" {
		provider, err := h.manager.GetActiveProvider()
		if err != nil {
			c.JSON(http.StatusNotFound, models.ErrorResponse(
				models.ErrNotFound,
				"No active provider",
			))
			return nil, false
		}
		return provider, true
	}
	return h.namedProvider(c, name)
}

// namedProvider validates an explicit provider name and fetches it from the
// registry, writing the error response on failure.
func (h *CloudHandler) namedProvider(c *gin.Context, name string) (cloud.CloudProvider, bool) {
	if !defaults.IsPublicProvider(name) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Provider is experimental and not available in this build",
		))
		return nil, false
	}
	provider, err := h.manager.GetProvider(name)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"Unknown provider: "+name,
		))
		return nil, false
	}
	return provider, true
}

func newOperationID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand failing is unrecoverable for ID generation; fall back to
		// a timestamp-based ID rather than panicking the request.
		return "op_t" + time.Now().UTC().Format("20060102150405.000000000")
	}
	return "op_" + hex.EncodeToString(buf)
}

// sanitizedInstanceResult is the credential-free subset of a created instance
// stored in the operation log. Connection secrets are served by the instances
// endpoints only.
type sanitizedInstanceResult struct {
	ID                string `json:"id"`
	Provider          string `json:"provider"`
	Label             string `json:"label"`
	Status            string `json:"status"`
	Region            string `json:"region"`
	Plan              string `json:"plan"`
	IPv4              string `json:"ipv4,omitempty"`
	IPv6              string `json:"ipv6,omitempty"`
	LastDeployWarning string `json:"lastDeployWarning,omitempty"`
}

func sanitizeInstanceResult(instance *cloud.Instance) sanitizedInstanceResult {
	if instance == nil {
		return sanitizedInstanceResult{}
	}
	return sanitizedInstanceResult{
		ID:                instance.ID,
		Provider:          instance.Provider,
		Label:             instance.Label,
		Status:            instance.Status,
		Region:            instance.Region,
		Plan:              instance.Plan,
		IPv4:              instance.IPv4,
		IPv6:              instance.IPv6,
		LastDeployWarning: instance.LastDeployWarning,
	}
}

// secretExtraKeyPattern matches CreateInstanceOptions.Extra keys whose values
// must be treated as secrets (SSH passwords, private keys, API tokens, ...).
var secretExtraKeyPattern = regexp.MustCompile(
	`(?i)(password|passwd|pwd|secret|passphrase|private[_-]?key|privkey|api[_-]?key|token|credential)`)

// errorRedactionPatterns removes common credential shapes from provider error
// text regardless of where the value came from. Ordering matters: the paired
// BEGIN/END private-key block is redacted before the unterminated fallback.
var errorRedactionPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----`),
	regexp.MustCompile(`(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*`),
	regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9\-._~+/=]+`),
	regexp.MustCompile(`(?i)\b(password|passwd|pwd|passphrase)\s*[=:]\s*\S+`),
	regexp.MustCompile(`(?i)\bapi[_-]?key\s*[=:]\s*\S+`),
	regexp.MustCompile(`(?i)\btoken\s*[=:]\s*\S+`),
	regexp.MustCompile(`(?i)\bsecret\s*[=:]\s*\S+`),
}

// sanitizeOperationError redacts credentials from a provider error before it
// is persisted or logged:
//
//  1. every secret value from this request's Extra map (all non-empty values
//     for the ssh provider, secret-named keys for the rest) is replaced by
//     exact match, and
//  2. common credential patterns (Bearer tokens, password=/token=/api_key=
//     pairs, PEM private-key blocks) are redacted by regex.
//
// The result is finally capped at 500 bytes so an unexpected payload echo
// cannot bloat the persistent log.
func sanitizeOperationError(err error, providerName string, opts *cloud.CreateInstanceOptions) string {
	if err == nil {
		return ""
	}
	msg := err.Error()

	if opts != nil {
		for key, value := range opts.Extra {
			value = strings.TrimSpace(value)
			if value == "" {
				continue
			}
			// The ssh provider's Extra carries connection credentials almost
			// exclusively, so all of its values are treated as secrets.
			if providerName == "ssh" || secretExtraKeyPattern.MatchString(key) {
				msg = strings.ReplaceAll(msg, value, "[REDACTED]")
			}
		}
	}

	for _, re := range errorRedactionPatterns {
		msg = re.ReplaceAllString(msg, "[REDACTED]")
	}

	const maxLen = 500
	if len(msg) > maxLen {
		msg = msg[:maxLen] + "… (truncated)"
	}
	return msg
}

// createRequestFingerprint canonicalizes every behavior-affecting input of a
// create request (provider, region, plan, label, host, osId, sshKeyId and the
// full Extra map — keys sorted by the JSON encoder) and
// returns a hex HMAC-SHA256 over it. HMAC keeps the stored fingerprint
// one-way: Extra may contain SSH passwords or private keys, and those must
// not be recoverable (or brute-forceable without the key) from the database.
func (h *CloudHandler) createRequestFingerprint(providerName string, opts *cloud.CreateInstanceOptions) string {
	// Preserve the exact values passed to the provider. Trimming here while
	// executing the raw request would let behaviorally different requests
	// share an idempotency fingerprint; trimming keys could also collapse
	// distinct map entries in iteration-dependent order.
	extra := make(map[string]string, len(opts.Extra))
	for key, value := range opts.Extra {
		extra[key] = value
	}
	// json.Marshal sorts map keys, which makes the encoding canonical.
	canonical, err := json.Marshal(map[string]any{
		"provider": providerName,
		"label":    opts.Label,
		"region":   opts.Region,
		"plan":     opts.Plan,
		"osId":     opts.OSID,
		"sshKeyId": opts.SSHKeyID,
		"host":     opts.Host,
		"extra":    extra,
	})
	if err != nil {
		// Cannot happen for this shape; keep a deterministic fallback anyway.
		canonical = []byte(providerName + "|" + opts.Region + "|" + opts.Plan)
	}
	mac := hmac.New(sha256.New, h.fingerprintKey)
	mac.Write(canonical)
	return hex.EncodeToString(mac.Sum(nil))
}

// sanitizeCreateSummary records only the non-sensitive shape of the request.
func sanitizeCreateSummary(opts *cloud.CreateInstanceOptions) string {
	summary, err := json.Marshal(map[string]string{
		"label":  opts.Label,
		"region": opts.Region,
		"plan":   opts.Plan,
	})
	if err != nil {
		return ""
	}
	return string(summary)
}

func redactProviderExtra(providerName string, extra map[string]string) map[string]string {
	if len(extra) == 0 {
		return map[string]string{}
	}

	redacted := make(map[string]string, len(extra))
	for key, value := range extra {
		redacted[key] = value
	}

	if providerName == "ssh" {
		delete(redacted, "password")
		delete(redacted, "privateKey")
		delete(redacted, "passphrase")
	}

	return redacted
}

// ListProviders returns all available cloud providers
func (h *CloudHandler) ListProviders(c *gin.Context) {
	log.Printf("[CloudHandler] ListProviders called")

	providerNames := h.manager.ListProviders()

	type ProviderInfo struct {
		Name        string `json:"name"`
		DisplayName string `json:"displayName"`
	}

	result := make([]ProviderInfo, 0, len(providerNames))
	for _, name := range providerNames {
		if !defaults.IsPublicProvider(name) {
			continue
		}
		provider, err := h.manager.GetProvider(name)
		if err != nil {
			log.Printf("[CloudHandler] Warning: Failed to get provider %s: %v", name, err)
			continue
		}

		result = append(result, ProviderInfo{
			Name:        provider.Name(),
			DisplayName: provider.DisplayName(),
		})
	}

	log.Printf("[CloudHandler] Found %d providers", len(result))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"providers": result,
	}))
}

// GetActiveProvider returns the current active provider
func (h *CloudHandler) GetActiveProvider(c *gin.Context) {
	log.Printf("[CloudHandler] GetActiveProvider called")

	provider, err := h.manager.GetActiveProvider()
	if err != nil {
		log.Printf("[CloudHandler] ERROR: No active provider: %v", err)
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"No active provider set",
		))
		return
	}
	if !defaults.IsPublicProvider(provider.Name()) {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"Active provider is not a public production provider",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"name":        provider.Name(),
		"displayName": provider.DisplayName(),
	}))
}

// SetActiveProvider sets the active cloud provider
func (h *CloudHandler) SetActiveProvider(c *gin.Context) {
	var req struct {
		Provider string `json:"provider" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] SetActiveProvider: %s", req.Provider)

	if !defaults.IsPublicProvider(req.Provider) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Provider is experimental and not available in this build",
		))
		return
	}

	if err := h.manager.SetActiveProvider(req.Provider); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to set provider: %v", err)
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Active provider set to: %s", req.Provider)
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"provider": req.Provider,
	}))
}

// GetConfig returns the configuration for the provider named by the
// ?provider= query parameter, falling back to the active provider when it is
// omitted (backwards compatibility with older clients).
func (h *CloudHandler) GetConfig(c *gin.Context) {
	log.Printf("[CloudHandler] GetConfig called (provider=%s)", c.Query("provider"))

	provider, ok := h.readProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	cfg, err := provider.LoadConfig()
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to load config: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to load configuration",
		))
		return
	}

	if cfg == nil {
		cfg = &cloud.ProviderConfig{
			Provider: provider.Name(),
			Extra:    map[string]string{},
		}
	}

	hasAPIKey := strings.TrimSpace(cfg.APIKey) != ""
	response := gin.H{
		"provider":      cfg.Provider,
		"defaultRegion": cfg.DefaultRegion,
		"defaultPlan":   cfg.DefaultPlan,
		"extra":         redactProviderExtra(cfg.Provider, cfg.Extra),
		"hasApiKey":     hasAPIKey,
	}

	c.JSON(http.StatusOK, models.SuccessResponse(response))
}

// SaveConfig saves the configuration for the provider named by the request
// body's `provider` field, falling back to the active provider when it is
// omitted (backwards compatibility with older clients).
func (h *CloudHandler) SaveConfig(c *gin.Context) {
	var cfg cloud.ProviderConfig

	if err := c.ShouldBindJSON(&cfg); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] SaveConfig for provider: %s", cfg.Provider)

	// The body's provider field, when present, selects the target provider
	// directly; there is no separate "mismatch" case anymore.
	provider, ok := h.readProvider(c, cfg.Provider)
	if !ok {
		return
	}

	cfg.Provider = provider.Name()
	if cfg.Extra == nil {
		cfg.Extra = map[string]string{}
	}

	if err := provider.ValidateConfig(&cfg); err != nil {
		log.Printf("[CloudHandler] ERROR: Config validation failed: %v", err)
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			err.Error(),
		))
		return
	}

	if err := provider.SaveConfig(&cfg); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to save config: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to save configuration",
		))
		return
	}

	log.Printf("[CloudHandler] Config saved successfully")
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Configuration saved successfully",
	}))
}

// ListInstances returns all instances for the provider named by the
// ?provider= query parameter, falling back to the active provider when it is
// omitted.
func (h *CloudHandler) ListInstances(c *gin.Context) {
	log.Printf("[CloudHandler] ListInstances called (provider=%s)", c.Query("provider"))

	provider, ok := h.readProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	instances, err := provider.ListInstances(c.Request.Context())
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list instances: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Listed %d instances", len(instances))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"instances": instances,
	}))
}

// CreateInstance starts an asynchronous instance-creation operation for an
// explicitly named provider and returns 202 with the operation record.
// Clients poll GET /cloud/operations/:id for pending → running →
// succeeded/failed, and may send an Idempotency-Key header to make retries
// safe: duplicate submissions return the original operation instead of
// creating a second instance.
func (h *CloudHandler) CreateInstance(c *gin.Context) {
	var req struct {
		Provider string `json:"provider"`
		cloud.CreateInstanceOptions
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"Invalid request body",
		))
		return
	}

	log.Printf("[CloudHandler] CreateInstance: provider=%s, region=%s, plan=%s, label=%s",
		req.Provider, req.Region, req.Plan, req.Label)

	provider, ok := h.requestProvider(c, req.Provider)
	if !ok {
		return
	}

	if h.db == nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Operation store is unavailable",
		))
		return
	}

	fingerprint := h.createRequestFingerprint(provider.Name(), &req.CreateInstanceOptions)

	// The idempotency lookup runs before the capacity check: a retry of an
	// already-accepted operation must be able to fetch it even when the
	// server is at its concurrent-create limit.
	idemKey := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
	if idemKey != "" {
		for {
			var existing models.CloudOperation
			err := h.db.Where("idempotency_key = ?", idemKey).First(&existing).Error
			switch {
			case err == nil:
				h.answerIdempotentReplay(c, &existing, fingerprint)
				return
			case !errors.Is(err, gorm.ErrRecordNotFound):
				log.Printf("[CloudHandler] ERROR: idempotency lookup failed: %v", err)
				c.JSON(http.StatusInternalServerError, models.ErrorResponse(
					models.ErrInternalError,
					"Failed to check idempotency key",
				))
				return
			}

			owner, done := h.beginIdempotencyInsert(idemKey)
			if owner {
				defer h.finishIdempotencyInsert(idemKey)
				break
			}
			select {
			case <-done:
				// The first request has finished its insert attempt. Re-check
				// the database; if it failed, this request may become owner.
				continue
			case <-c.Request.Context().Done():
				return
			}
		}
	}

	// Acquire a background-create slot (non-blocking). Released by
	// runCreateInstance when the operation finishes, or below on the error
	// paths where the goroutine is never started.
	select {
	case h.createSem <- struct{}{}:
	default:
		c.JSON(http.StatusTooManyRequests, models.ErrorResponse(
			models.ErrTooManyOperations,
			"Too many concurrent create operations; retry after one finishes",
		))
		return
	}

	op := models.CloudOperation{
		ID:                 newOperationID(),
		Type:               models.OpTypeCreateInstance,
		Provider:           provider.Name(),
		Status:             models.OpStatusPending,
		RequestFingerprint: fingerprint,
		RequestSummary:     sanitizeCreateSummary(&req.CreateInstanceOptions),
	}
	if idemKey != "" {
		op.IdempotencyKey = &idemKey
	}

	if err := h.db.Create(&op).Error; err != nil {
		<-h.createSem // the background operation will not start
		// A concurrent request with the same Idempotency-Key may have won the
		// unique index; answer with the winner instead of failing.
		if idemKey != "" {
			var existing models.CloudOperation
			if ferr := h.db.Where("idempotency_key = ?", idemKey).First(&existing).Error; ferr == nil {
				h.answerIdempotentReplay(c, &existing, fingerprint)
				return
			}
		}
		log.Printf("[CloudHandler] ERROR: failed to persist operation: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to persist operation",
		))
		return
	}

	opts := req.CreateInstanceOptions
	go h.runCreateInstance(op.ID, provider, &opts)

	c.Header("Location", "/api/v1/cloud/operations/"+op.ID)
	c.JSON(http.StatusAccepted, models.SuccessResponse(gin.H{"operation": op}))
}

// answerIdempotentReplay responds to a create request whose Idempotency-Key
// already has a stored operation: 202 with the original operation when the
// request fingerprint matches, 409 when the same key is being reused for a
// different request.
func (h *CloudHandler) answerIdempotentReplay(c *gin.Context, existing *models.CloudOperation, fingerprint string) {
	if existing.RequestFingerprint != fingerprint {
		c.JSON(http.StatusConflict, models.ErrorResponse(
			models.ErrIdempotencyConflict,
			"Idempotency-Key was already used with a different request",
		))
		return
	}
	c.Header("Location", "/api/v1/cloud/operations/"+existing.ID)
	c.JSON(http.StatusAccepted, models.SuccessResponse(gin.H{"operation": existing}))
}

// runCreateInstance executes the provider call in the background. It is
// deliberately detached from the HTTP request context: the request has
// already returned 202, so the operation must keep running (and stay
// queryable) after that context is canceled.
func (h *CloudHandler) runCreateInstance(opID string, provider cloud.CloudProvider, opts *cloud.CreateInstanceOptions) {
	defer func() { <-h.createSem }() // release the concurrency slot

	ctx, cancel := context.WithTimeout(context.Background(), createInstanceTimeout)
	defer cancel()

	h.updateOperation(opID, map[string]any{"status": models.OpStatusRunning})

	instance, err := provider.CreateInstance(ctx, opts)
	if err != nil {
		// Sanitize before logging too: the raw provider error may echo
		// request secrets (e.g. an SSH password from Extra).
		msg := sanitizeOperationError(err, provider.Name(), opts)
		log.Printf("[CloudHandler] ERROR: operation %s failed: %s", opID, msg)
		h.updateOperation(opID, map[string]any{
			"status": models.OpStatusFailed,
			"error":  msg,
		})
		return
	}

	result, err := json.Marshal(sanitizeInstanceResult(instance))
	if err != nil {
		result = []byte("{}")
	}
	log.Printf("[CloudHandler] Operation %s succeeded", opID)
	h.updateOperation(opID, map[string]any{
		"status": models.OpStatusSucceeded,
		"result": string(result),
	})
}

// updateOperation persists operation state. Terminal updates (succeeded /
// failed) are retried with a bounded incremental backoff: losing one would
// leave the operation "running" forever, which clients poll on. Non-terminal
// updates are best-effort single attempts.
func (h *CloudHandler) updateOperation(opID string, fields map[string]any) {
	status, _ := fields["status"].(string)
	maxAttempts := 1
	if status == models.OpStatusSucceeded || status == models.OpStatusFailed {
		maxAttempts = terminalUpdateMaxAttempts
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if attempt > 1 {
			// Incremental backoff: base, 2×base, 3×base, ...
			time.Sleep(time.Duration(attempt-1) * h.terminalRetryBackoff)
		}
		err := h.db.Model(&models.CloudOperation{}).Where("id = ?", opID).Updates(fields).Error
		if err == nil {
			return
		}
		lastErr = err
		if maxAttempts > 1 {
			log.Printf("[CloudHandler] WARN: terminal update of operation %s failed (attempt %d/%d): %v",
				opID, attempt, maxAttempts, err)
			if h.onTerminalUpdateRetry != nil {
				h.onTerminalUpdateRetry(attempt, err)
			}
		}
	}
	log.Printf("[CloudHandler] ERROR: failed to update operation %s to %q after %d attempt(s): %v",
		opID, status, maxAttempts, lastErr)
}

// GetOperation returns the persisted state of a cloud operation.
func (h *CloudHandler) GetOperation(c *gin.Context) {
	if h.db == nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Operation store is unavailable",
		))
		return
	}

	var op models.CloudOperation
	err := h.db.First(&op, "id = ?", c.Param("id")).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, models.ErrorResponse(
			models.ErrNotFound,
			"Operation not found",
		))
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrInternalError,
			"Failed to load operation",
		))
		return
	}

	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{"operation": op}))
}

// DestroyInstance destroys an instance. The target provider must be named
// explicitly via the `provider` query parameter — the destroy must not depend
// on the shared activeProvider, which another client may change at any time.
func (h *CloudHandler) DestroyInstance(c *gin.Context) {
	instanceID := c.Param("id")

	log.Printf("[CloudHandler] DestroyInstance: %s (provider=%s)", instanceID, c.Query("provider"))

	provider, ok := h.requestProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	if err := provider.DestroyInstance(c.Request.Context(), instanceID); err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to destroy instance: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Instance destroyed: %s", instanceID)
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"message": "Instance destroyed successfully",
	}))
}

// ListRegions returns all regions for the provider named by the ?provider=
// query parameter, falling back to the active provider when it is omitted.
func (h *CloudHandler) ListRegions(c *gin.Context) {
	log.Printf("[CloudHandler] ListRegions called (provider=%s)", c.Query("provider"))

	provider, ok := h.readProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	regions, err := provider.ListRegions(c.Request.Context())
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list regions: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Listed %d regions", len(regions))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"regions": regions,
	}))
}

// ListPlans returns all plans for the provider named by the ?provider= query
// parameter, falling back to the active provider when it is omitted.
func (h *CloudHandler) ListPlans(c *gin.Context) {
	region := c.Query("region")
	log.Printf("[CloudHandler] ListPlans called (provider=%s, region: %s)", c.Query("provider"), region)

	provider, ok := h.readProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	plans, err := provider.ListPlans(c.Request.Context(), region)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list plans: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Listed %d plans", len(plans))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"plans": plans,
	}))
}

// ListAvailability returns plan availability for a region
func (h *CloudHandler) ListAvailability(c *gin.Context) {
	region := c.Query("region")
	if region == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse(
			models.ErrValidationError,
			"region parameter is required",
		))
		return
	}

	log.Printf("[CloudHandler] ListAvailability for region: %s (provider=%s)", region, c.Query("provider"))

	provider, ok := h.readProvider(c, c.Query("provider"))
	if !ok {
		return
	}

	availability, err := provider.ListAvailability(c.Request.Context(), region)
	if err != nil {
		log.Printf("[CloudHandler] ERROR: Failed to list availability: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse(
			models.ErrProviderError,
			err.Error(),
		))
		return
	}

	log.Printf("[CloudHandler] Listed %d available plans", len(availability))
	c.JSON(http.StatusOK, models.SuccessResponse(gin.H{
		"availability": availability,
	}))
}
