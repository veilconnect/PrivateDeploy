package models

import "time"

// Cloud operation statuses.
const (
	OpStatusPending   = "pending"
	OpStatusRunning   = "running"
	OpStatusSucceeded = "succeeded"
	OpStatusFailed    = "failed"
)

// Cloud operation types.
const (
	OpTypeCreateInstance = "create_instance"
)

// Error codes specific to asynchronous cloud operations. Kept next to the
// operation model (rather than response.go) because they only make sense for
// the operation endpoints.
const (
	// ErrIdempotencyConflict (HTTP 409): the Idempotency-Key was already used
	// with a different request payload.
	ErrIdempotencyConflict = "IDEMPOTENCY_CONFLICT"
	// ErrTooManyOperations (HTTP 429): the server is already running the
	// maximum number of concurrent background create operations.
	ErrTooManyOperations = "TOO_MANY_OPERATIONS"
)

// CloudOperation tracks a long-running cloud action (currently instance
// creation) so clients can poll its state and duplicate submissions can be
// deduplicated via Idempotency-Key. Persisted in SQLite so a process restart
// never silently loses a known operation.
//
// Result and Error are pre-sanitized before storage: they must never contain
// API keys, node passwords or other credentials. Full node connection details
// stay in the provider's node records and are served by the instances
// endpoints, not by the operation log.
type CloudOperation struct {
	ID       string `gorm:"primaryKey;size:64" json:"id"`
	Type     string `gorm:"size:32;index" json:"type"`
	Provider string `gorm:"size:32" json:"provider"`
	Status   string `gorm:"size:16;index" json:"status"`
	// IdempotencyKey is a pointer so operations submitted without a key are
	// stored as NULL and never collide on the unique index.
	IdempotencyKey *string `gorm:"uniqueIndex;size:255" json:"idempotencyKey,omitempty"`
	// RequestFingerprint is a hex HMAC-SHA256 over the canonicalized create
	// request (provider/region/plan/label/host/extra, map keys sorted while raw
	// values are preserved). It binds an Idempotency-Key to the request that first used it:
	// a replay with the same key but a different fingerprint is rejected with
	// 409. Because it is a keyed one-way hash, no secret from the request
	// (e.g. SSH passwords in Extra) can be recovered from the stored value.
	RequestFingerprint string    `gorm:"size:64" json:"-"`
	RequestSummary     string    `json:"requestSummary,omitempty"`
	Result             string    `json:"result,omitempty"`
	Error              string    `json:"error,omitempty"`
	CreatedAt          time.Time `json:"createdAt"`
	UpdatedAt          time.Time `json:"updatedAt"`
}
