// Package cdn manages optional Cloudflare Workers as a CDN front for cloud
// nodes. Mirrors mobile/lib/features/cdn/cdn_provider.dart so behavior is
// the same across mobile and desktop.
//
// One Worker per cloud node, named "pd-relay-<short-id>". The Worker is a
// thin WS<->TCP relay; it holds NO credentials. Auth still happens at the
// VLESS UUID layer on the VPS.
package cdn

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	verifyEndpoint   = "https://api.cloudflare.com/client/v4/user/tokens/verify"
	accountsEndpoint = "https://api.cloudflare.com/client/v4/accounts"

	// Compatibility date the Worker is uploaded with. Bumping this can
	// change runtime behavior, so it lives next to the worker template.
	workerCompatDate = "2024-09-23"

	configFileRel      = "data/cdn/config.json"
	deploymentsFileRel = "data/cdn/deployments.json"
)

// Status mirrors mobile CdnStatus.
type Status string

const (
	StatusDisabled   Status = "disabled"
	StatusUnverified Status = "unverified"
	StatusVerified   Status = "verified"
)

// State is the public snapshot returned to Vue. Token is intentionally
// omitted — the frontend never needs the raw token.
type State struct {
	Status            Status                 `json:"status"`
	AccountID         string                 `json:"accountId,omitempty"`
	AccountEmail      string                 `json:"accountEmail,omitempty"`
	WorkersSubdomain  string                 `json:"workersSubdomain,omitempty"`
	LastError         string                 `json:"lastError,omitempty"`
	WorkersDevExample string                 `json:"workersDevExample,omitempty"`
	Deployments       map[string]*Deployment `json:"deployments"`
	CustomDomain      *CustomDomain          `json:"customDomain,omitempty"`
}

// Deployment describes one Worker scoped to one cloud node.
//
// CustomHost / CustomDomainID are populated when M1's Workers Custom Domains
// binding has been applied. CustomDomainID is the id returned by
// PUT /accounts/{aid}/workers/domains and lets DeleteWorker detach the
// binding (which cascades the auto-created DNS record) without re-resolving
// by hostname.
//
// ZoneID / RouteID / DNSRecordID are legacy fields from the route+CNAME
// implementation that pre-dated Workers Custom Domains. They are still
// honored by DeleteWorker as a fallback path so any persisted state from
// the old format cleans up correctly; new deploys do not populate them.
type Deployment struct {
	NodeID         string    `json:"nodeId"`
	ScriptName     string    `json:"scriptName"`
	WorkerHost     string    `json:"workerHost"`
	Backend        string    `json:"backend"`
	DeployedAt     time.Time `json:"deployedAt"`
	CustomHost     string    `json:"customHost,omitempty"`
	CustomDomainID string    `json:"customDomainId,omitempty"`
	// CustomHostStatus tracks Cloudflare-side readiness of the bound
	// hostname. Values: "" (no custom host), "pending" (attached but
	// cert/edge propagation not yet confirmed), "active" (TLS handshake
	// succeeded), "failed" (probe gave up after retries). Subscription
	// emission only routes traffic through the customHost when active —
	// users who connect immediately after attach won't hit a half-cooked
	// cert.
	CustomHostStatus string `json:"customHostStatus,omitempty"`
	// AccountID pins this deployment to the CF account it was deployed
	// against. DeleteWorker uses it (falling back to the manager's current
	// account only when missing — for old persisted records). Without
	// this, a user who re-verifies with a different account would have
	// detach/delete-script silently 404 against the new account, the
	// orphan resources would stay on the old account, and we'd remove
	// the local record under the wrong assumption that they were cleaned
	// up.
	AccountID string `json:"accountId,omitempty"`
	// PathSecret is a per-deployment 32-hex random injected into the Worker
	// at upload time as PATH_SECRET. The client appends ?k=<secret> to the
	// VLESS-WS path; the Worker rejects every request that lacks the
	// matching value with a bare 404 (no body, no app branding). Without
	// this, anyone who learns the Worker hostname could use it as a free
	// TCP-out relay against the VPS relay port — annoying both as a quota
	// drain on the user's Cloudflare account and as a fingerprintable
	// "PrivateDeploy CDN relay" landing page on the prior plain-GET path.
	// Empty string means "deployed before the path-secret gate landed";
	// the Worker template falls through to its old behaviour in that case
	// so an app upgrade doesn't break in-flight tunnels until the user
	// redeploys.
	PathSecret string `json:"pathSecret,omitempty"`
	// Deprecated: legacy route+CNAME fields, retained for cleanup of older
	// persisted deployments. New deploys leave these empty.
	ZoneID      string `json:"zoneId,omitempty"`
	RouteID     string `json:"routeId,omitempty"`
	DNSRecordID string `json:"dnsRecordId,omitempty"`
}

// persistedConfig is the on-disk representation of the verifier state. The
// raw token IS kept on disk; mobile uses platform secure storage for this,
// but the desktop Wails app already keeps Vultr/DO API keys in the same
// data/ directory so we follow the established pattern.
type persistedConfig struct {
	Token            string        `json:"token,omitempty"`
	AccountID        string        `json:"accountId,omitempty"`
	AccountEmail     string        `json:"accountEmail,omitempty"`
	WorkersSubdomain string        `json:"workersSubdomain,omitempty"`
	CustomDomain     *CustomDomain `json:"customDomain,omitempty"`
}

// Manager owns CDN state. One per process.
type Manager struct {
	mu          sync.Mutex
	basePath    string
	httpClient  *http.Client
	workerTpl   string
	cfg         persistedConfig
	deployments map[string]*Deployment

	// Operation-flight flags so the UI can disable buttons.
	verifying bool
	deploying bool

	// Last error message presented to the UI.
	lastError string
}

//go:embed assets/worker.js
var embeddedAssets embed.FS

// NewManager builds and loads state from disk. basePath is typically
// Env.BasePath. If the worker template can't be loaded, deploy operations
// will fail loudly later — load doesn't fail.
func NewManager(basePath string) *Manager {
	m := &Manager{
		basePath: basePath,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		deployments: map[string]*Deployment{},
	}
	if data, err := embeddedAssets.ReadFile("assets/worker.js"); err == nil {
		m.workerTpl = string(data)
	}
	m.load()
	return m
}

// State returns the current public state snapshot.
func (m *Manager) State() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshotLocked()
}

// snapshotLocked builds a State while the mutex is held.
func (m *Manager) snapshotLocked() State {
	deps := make(map[string]*Deployment, len(m.deployments))
	for k, v := range m.deployments {
		copy := *v
		deps[k] = &copy
	}

	status := StatusDisabled
	if strings.TrimSpace(m.cfg.Token) != "" {
		if strings.TrimSpace(m.cfg.AccountID) != "" {
			status = StatusVerified
		} else {
			status = StatusUnverified
		}
	}

	example := ""
	if sub := strings.TrimSpace(m.cfg.WorkersSubdomain); sub != "" {
		example = fmt.Sprintf("pd-relay-<your-name>.%s.workers.dev", sub)
	}

	var custom *CustomDomain
	if m.cfg.CustomDomain != nil && m.cfg.CustomDomain.IsSet() {
		c := *m.cfg.CustomDomain
		custom = &c
	}

	return State{
		Status:            status,
		AccountID:         m.cfg.AccountID,
		AccountEmail:      m.cfg.AccountEmail,
		WorkersSubdomain:  m.cfg.WorkersSubdomain,
		LastError:         m.lastError,
		WorkersDevExample: example,
		Deployments:       deps,
		CustomDomain:      custom,
	}
}

// VerifyAndPersist runs /user/tokens/verify, lists accounts, fetches the
// workers.dev subdomain. On success persists everything and switches to
// verified.
func (m *Manager) VerifyAndPersist(ctx context.Context, token string) (State, error) {
	m.mu.Lock()
	if m.verifying {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("verification already in flight")
	}
	priorVerified := strings.TrimSpace(m.cfg.AccountID) != ""
	m.verifying = true
	m.lastError = ""
	m.mu.Unlock()

	defer func() {
		m.mu.Lock()
		m.verifying = false
		m.mu.Unlock()
	}()

	token = strings.TrimSpace(token)
	if token == "" {
		m.setLastError("empty token")
		return m.State(), errors.New("empty token")
	}

	// 1. Verify token.
	verifyBody, status, err := m.cfGetJSON(ctx, token, verifyEndpoint)
	if err != nil {
		return m.failVerify(priorVerified, fmt.Sprintf("network error verifying token: %v", err))
	}
	if status != http.StatusOK || !cfSuccess(verifyBody) {
		msg := extractCfError(verifyBody)
		if msg == "" {
			msg = fmt.Sprintf("token verification failed (HTTP %d)", status)
		}
		return m.failVerify(priorVerified, msg)
	}
	verifyResult, _ := verifyBody["result"].(map[string]any)
	if s, _ := verifyResult["status"].(string); s != "active" {
		return m.failVerify(priorVerified, "token is not active")
	}

	// 2. List accounts.
	accBody, accStatus, err := m.cfGetJSON(ctx, token, accountsEndpoint)
	if err != nil {
		return m.failVerify(priorVerified, fmt.Sprintf("network error listing accounts: %v", err))
	}
	if accStatus != http.StatusOK {
		msg := extractCfError(accBody)
		if msg == "" {
			msg = fmt.Sprintf("listing accounts failed (HTTP %d)", accStatus)
		}
		return m.failVerify(priorVerified, msg)
	}
	accounts, _ := accBody["result"].([]any)
	if len(accounts) == 0 {
		return m.failVerify(priorVerified, "token has no accessible Cloudflare accounts")
	}
	first, _ := accounts[0].(map[string]any)
	accountID, _ := first["id"].(string)
	if accountID == "" {
		return m.failVerify(priorVerified, "could not parse account id from Cloudflare response")
	}
	email, _ := verifyResult["email"].(string)
	if email == "" {
		email, _ = first["name"].(string)
	}

	// 3. Fetch workers.dev subdomain (404 is non-fatal).
	subURL := fmt.Sprintf("%s/%s/workers/subdomain", accountsEndpoint, accountID)
	subBody, subStatus, _ := m.cfGetJSON(ctx, token, subURL)
	workersSub := ""
	if subStatus == http.StatusOK {
		if r, ok := subBody["result"].(map[string]any); ok {
			workersSub, _ = r["subdomain"].(string)
		}
	}

	// Persist + announce. Re-verify with the *same* account preserves the
	// existing CustomDomain config (a token rotation shouldn't lose the
	// user's M1 binding); switching to a *different* account drops it,
	// because the saved zoneId is account-scoped and would silently 404
	// when the next deploy tried to attach. The user has to re-pick a
	// zone visible to the new account.
	m.mu.Lock()
	priorCustomDomain := m.cfg.CustomDomain
	priorAccount := strings.TrimSpace(m.cfg.AccountID)
	var preservedCustomDomain *CustomDomain
	if priorAccount != "" && priorAccount == accountID {
		preservedCustomDomain = priorCustomDomain
	}
	m.cfg = persistedConfig{
		Token:            token,
		AccountID:        accountID,
		AccountEmail:     email,
		WorkersSubdomain: workersSub,
		CustomDomain:     preservedCustomDomain,
	}
	if workersSub == "" {
		m.lastError = "Token verified, but no workers.dev subdomain claimed yet — visit the Workers dashboard once to claim one."
	} else {
		m.lastError = ""
	}
	if err := m.saveConfigLocked(); err != nil {
		m.lastError = fmt.Sprintf("verified but failed to persist: %v", err)
	}
	state := m.snapshotLocked()
	m.mu.Unlock()
	return state, nil
}

// failVerify rolls state back to disabled (or unverified if a verified
// token was already on disk) and records the error.
func (m *Manager) failVerify(priorVerified bool, msg string) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.lastError = msg
	if !priorVerified {
		m.cfg = persistedConfig{}
		_ = m.saveConfigLocked()
	}
	return m.snapshotLocked(), errors.New(msg)
}

// Clear wipes all CDN state from disk. Best-effort cleanup of remote
// resources (Workers, custom-domain bindings) runs first while we still
// have credentials; failures there are swallowed so a transient network
// problem can't block the user from removing local state. Any leftover
// CF resources can be cleaned via the dashboard.
//
// Order matters: snapshot deployment IDs under the lock, drop the lock
// while doing the network calls (DeleteWorker takes its own lock), then
// re-acquire to wipe.
func (m *Manager) Clear(ctx context.Context) (State, error) {
	m.mu.Lock()
	ids := make([]string, 0, len(m.deployments))
	for id := range m.deployments {
		ids = append(ids, id)
	}
	m.mu.Unlock()

	for _, id := range ids {
		// Per-call timeout so a stuck CF API call can't pin the whole
		// "remove token" UI for minutes.
		dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		_, _ = m.DeleteWorker(dctx, id)
		cancel()
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.cfg = persistedConfig{}
	m.deployments = map[string]*Deployment{}
	m.lastError = ""
	if err := m.saveConfigLocked(); err != nil {
		return m.snapshotLocked(), err
	}
	if err := m.saveDeploymentsLocked(); err != nil {
		return m.snapshotLocked(), err
	}
	return m.snapshotLocked(), nil
}

// DeployWorker uploads (or updates) a Worker for the given node.
// backendHost+backendPort must be the VPS-side plain VLESS relay endpoint.
func (m *Manager) DeployWorker(ctx context.Context, nodeID, nodeLabel, backendHost string, backendPort int) (State, error) {
	m.mu.Lock()
	if m.deploying {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("deploy already in flight")
	}
	if strings.TrimSpace(m.cfg.AccountID) == "" {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("token not verified — verify it first")
	}
	// Hard requirement only when no M1 custom-domain is configured. A
	// claimed workers.dev subdomain is one of two ways to reach the
	// Worker — when the user has bound a custom hostname we can ship
	// without it, which lets accounts that have never visited the
	// Workers dashboard still use M1.
	hasCustomDomain := m.cfg.CustomDomain != nil && m.cfg.CustomDomain.IsSet()
	if strings.TrimSpace(m.cfg.WorkersSubdomain) == "" && !hasCustomDomain {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("no workers.dev subdomain claimed and no custom domain bound — claim one in the Workers dashboard, or bind a custom hostname under CDN settings")
	}
	if backendPort <= 0 || strings.TrimSpace(backendHost) == "" {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("backend host:port required")
	}
	if m.workerTpl == "" {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("worker template missing from binary")
	}
	token := m.cfg.Token
	accountID := m.cfg.AccountID
	subdomain := m.cfg.WorkersSubdomain
	m.deploying = true
	m.lastError = ""
	m.mu.Unlock()

	defer func() {
		m.mu.Lock()
		m.deploying = false
		m.mu.Unlock()
	}()

	backend := fmt.Sprintf("%s:%d", backendHost, backendPort)
	// 32 hex chars = 128 bits of entropy. Plenty for a per-deployment secret
	// that lives in a TLS query string and rotates on every redeploy.
	pathSecret, err := randomHex(16)
	if err != nil {
		m.setLastError(fmt.Sprintf("failed to generate path secret: %v", err))
		return m.State(), err
	}
	body := strings.ReplaceAll(
		m.workerTpl,
		`'__BACKEND_PLACEHOLDER__'`,
		fmt.Sprintf(`'%s'`, escapeJSString(backend)),
	)
	body = strings.ReplaceAll(
		body,
		`'__PATH_SECRET_PLACEHOLDER__'`,
		fmt.Sprintf(`'%s'`, escapeJSString(pathSecret)),
	)
	// Both placeholders must have been resolved. Leaving them in would
	// either ship a worker that always 502s (the BACKEND string can't be
	// parsed as host:port) or — for PATH_SECRET — one whose "secret" is
	// the literal well-known placeholder. Match the *quoted* form: it's
	// the exact replaceAll target. The unquoted form also appears in the
	// template's doc-comment block, which is fine to keep post-render.
	if strings.Contains(body, `'__BACKEND_PLACEHOLDER__'`) {
		m.setLastError("worker template missing BACKEND placeholder")
		return m.State(), errors.New("worker template missing BACKEND placeholder")
	}
	if strings.Contains(body, `'__PATH_SECRET_PLACEHOLDER__'`) {
		m.setLastError("worker template missing PATH_SECRET placeholder")
		return m.State(), errors.New("worker template missing PATH_SECRET placeholder")
	}

	scriptName := safeWorkerName(nodeID, nodeLabel)
	uploadURL := fmt.Sprintf("%s/%s/workers/scripts/%s", accountsEndpoint, accountID, scriptName)

	// Multipart body: metadata JSON + worker.mjs module.
	buf := &bytes.Buffer{}
	mw := multipart.NewWriter(buf)
	metaHdr := textproto.MIMEHeader{}
	metaHdr.Set("Content-Disposition", `form-data; name="metadata"`)
	metaHdr.Set("Content-Type", "application/json")
	metaPart, err := mw.CreatePart(metaHdr)
	if err == nil {
		_ = json.NewEncoder(metaPart).Encode(map[string]any{
			"main_module":        "worker.mjs",
			"compatibility_date": workerCompatDate,
		})
	}
	scriptHdr := textproto.MIMEHeader{}
	scriptHdr.Set("Content-Disposition", `form-data; name="worker.mjs"; filename="worker.mjs"`)
	scriptHdr.Set("Content-Type", "application/javascript+module")
	scriptPart, err := mw.CreatePart(scriptHdr)
	if err == nil {
		_, _ = io.WriteString(scriptPart, body)
	}
	if err := mw.Close(); err != nil {
		m.setLastError(fmt.Sprintf("failed to encode multipart upload: %v", err))
		return m.State(), err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, uploadURL, buf)
	if err != nil {
		m.setLastError(err.Error())
		return m.State(), err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := m.httpClient.Do(req)
	if err != nil {
		m.setLastError(fmt.Sprintf("network error uploading Worker: %v", err))
		return m.State(), err
	}
	respBody, _ := readJSONBody(resp)
	if resp.StatusCode >= 400 {
		msg := extractCfError(respBody)
		if msg == "" {
			msg = fmt.Sprintf("worker upload failed (HTTP %d)", resp.StatusCode)
		}
		m.setLastError(msg)
		return m.State(), errors.New(msg)
	}

	// Enable workers.dev subdomain for the script — only meaningful when a
	// subdomain has been claimed. When we're shipping via custom-domain
	// only, skip the POST entirely; sending it would 404 against the
	// nonexistent subdomain and we'd surface a confusing error even
	// though the deploy is fine.
	host := ""
	if subdomain != "" {
		enableURL := fmt.Sprintf("%s/%s/workers/scripts/%s/subdomain", accountsEndpoint, accountID, scriptName)
		enableReq, err := http.NewRequestWithContext(ctx, http.MethodPost, enableURL,
			strings.NewReader(`{"enabled":true}`))
		if err != nil {
			m.setLastError(err.Error())
			return m.State(), err
		}
		enableReq.Header.Set("Authorization", "Bearer "+token)
		enableReq.Header.Set("Content-Type", "application/json")
		enableResp, err := m.httpClient.Do(enableReq)
		if err != nil {
			m.setLastError(fmt.Sprintf("worker uploaded but subdomain enable failed: %v", err))
			return m.State(), err
		}
		enableBody, _ := readJSONBody(enableResp)
		if enableResp.StatusCode >= 400 {
			msg := extractCfError(enableBody)
			if msg == "" {
				msg = fmt.Sprintf("worker uploaded but subdomain enable failed (HTTP %d)", enableResp.StatusCode)
			}
			m.setLastError(msg)
			return m.State(), errors.New(msg)
		}
		host = fmt.Sprintf("%s.%s.workers.dev", scriptName, subdomain)
	}
	dep := &Deployment{
		NodeID:     nodeID,
		ScriptName: scriptName,
		WorkerHost: host,
		Backend:    backend,
		DeployedAt: time.Now().UTC(),
		AccountID:  accountID,
		PathSecret: pathSecret,
	}

	// M1: if a CustomDomain is configured, attach this Worker to the user's
	// hostname via the Workers Custom Domains API. CF auto-creates DNS +
	// managed cert; one PUT replaces the older two-step (DNS CNAME + Worker
	// route) flow and drops two zone-level token scopes. Failure is
	// non-fatal — the workers.dev path still works and the error surfaces
	// through lastError so the user can re-deploy after fixing scope.
	customDomainCopy, _ := m.cloneCustomDomainConfig()
	customWarn := ""
	if customDomainCopy.IsSet() {
		customHost := customDomainCopy.hostForScript(scriptName)
		if customHost == "" {
			// hostForScript fail-closed (scriptName missing the standard
			// 6-hex tail). Skip Custom Domain attach — workers.dev path
			// still works.
			customWarn = "custom-domain binding skipped: script name lacks standard hash suffix"
		} else {
			bind, err := m.attachWorkerCustomDomain(ctx, token, accountID, customHost, scriptName, customDomainCopy.ZoneID)
			if err != nil {
				customWarn = fmt.Sprintf("workers.dev path live, but custom-domain binding failed: %v", err)
			} else {
				dep.CustomHost = bind.Hostname
				dep.CustomDomainID = bind.ID
				dep.CustomHostStatus = customHostStatusPending
				go m.probeCustomHostReadiness(nodeID, bind.Hostname)
				// Single-point-of-failure guard: a custom-domain-only deploy
				// (host == "" because no workers.dev subdomain was claimed)
				// leaves no sibling in the client's urltest pool, so if the
				// custom hostname stalls in provisioning the node has zero
				// working CDN entry points. Surface it so the user claims a
				// workers.dev subdomain for a backup route.
				if host == "" {
					customWarn = "CDN deployed via custom domain only — no workers.dev fallback. Claim a workers.dev subdomain so the node keeps a backup route if the custom hostname stalls."
				}
			}
		}
	}

	m.mu.Lock()
	m.deployments[nodeID] = dep
	if customWarn != "" {
		m.lastError = customWarn
	} else {
		m.lastError = ""
	}
	if err := m.saveDeploymentsLocked(); err != nil {
		m.lastError = fmt.Sprintf("deployed but failed to persist: %v", err)
	}
	state := m.snapshotLocked()
	m.mu.Unlock()
	return state, nil
}

// cloneCustomDomainConfig returns a value-copy of the persisted CustomDomain
// (zero value if none) plus the auth token. Holds the lock briefly so the
// caller can run network I/O without blocking other CDN ops.
func (m *Manager) cloneCustomDomainConfig() (CustomDomain, string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cfg.CustomDomain == nil {
		return CustomDomain{}, m.cfg.Token
	}
	return *m.cfg.CustomDomain, m.cfg.Token
}

// DeleteWorker removes a previously-deployed Worker from CF and local state.
// 404 from CF is treated as success.
func (m *Manager) DeleteWorker(ctx context.Context, nodeID string) (State, error) {
	m.mu.Lock()
	dep, ok := m.deployments[nodeID]
	if !ok {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, nil
	}
	if strings.TrimSpace(m.cfg.AccountID) == "" {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("account id missing — re-verify token first")
	}
	token := m.cfg.Token
	// Pin to the deployment's recorded account; only fall back to the
	// current verified account for legacy records that pre-date this
	// field. This way a user who re-verifies with a new account doesn't
	// silently 404 against the new account and orphan resources on the
	// old one.
	accountID := dep.AccountID
	if accountID == "" {
		accountID = m.cfg.AccountID
	}
	scriptName := dep.ScriptName
	customDomainID := dep.CustomDomainID
	legacyZoneID := dep.ZoneID
	legacyRouteID := dep.RouteID
	legacyDNSID := dep.DNSRecordID
	m.mu.Unlock()

	// Tear down the M1 custom-domain binding first. Best-effort: 404 means
	// the binding is already gone (CF's UI or another tool may have removed
	// it). A non-404 error is surfaced through lastError but does not abort
	// the script delete — leaving the CF Worker in place while a custom
	// domain points at it would be the worst outcome.
	//
	// Two paths because old persisted state (pre-Workers-Custom-Domains
	// refactor) still needs cleanup. New deploys only use CustomDomainID.
	if customDomainID != "" {
		if err := m.detachWorkerCustomDomain(ctx, token, accountID, customDomainID); err != nil {
			m.setLastError(fmt.Sprintf("custom-domain detach failed: %v", err))
		}
	} else {
		if legacyRouteID != "" {
			if err := m.legacyDeleteWorkerRoute(ctx, token, legacyZoneID, legacyRouteID); err != nil {
				m.setLastError(fmt.Sprintf("legacy worker route cleanup failed: %v", err))
			}
		}
		if legacyDNSID != "" {
			if err := m.legacyDeleteDNSRecord(ctx, token, legacyZoneID, legacyDNSID); err != nil {
				m.setLastError(fmt.Sprintf("legacy custom-domain DNS cleanup failed: %v", err))
			}
		}
	}

	deleteURL := fmt.Sprintf("%s/%s/workers/scripts/%s", accountsEndpoint, accountID, scriptName)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, deleteURL, nil)
	if err != nil {
		m.setLastError(err.Error())
		return m.State(), err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := m.httpClient.Do(req)
	if err != nil {
		m.setLastError(fmt.Sprintf("network error deleting Worker: %v", err))
		return m.State(), err
	}
	body, _ := readJSONBody(resp)
	if resp.StatusCode >= 400 && resp.StatusCode != http.StatusNotFound {
		msg := extractCfError(body)
		if msg == "" {
			msg = fmt.Sprintf("worker delete failed (HTTP %d)", resp.StatusCode)
		}
		m.setLastError(msg)
		return m.State(), errors.New(msg)
	}

	m.mu.Lock()
	delete(m.deployments, nodeID)
	m.lastError = ""
	if err := m.saveDeploymentsLocked(); err != nil {
		m.lastError = fmt.Sprintf("deleted but failed to persist: %v", err)
	}
	state := m.snapshotLocked()
	m.mu.Unlock()
	return state, nil
}

// ListZones returns the active zones the verified token can see. Used by
// the Settings UI to populate the M1 "use custom domain" zone picker.
func (m *Manager) ListZones(ctx context.Context) ([]Zone, error) {
	m.mu.Lock()
	if strings.TrimSpace(m.cfg.AccountID) == "" {
		m.mu.Unlock()
		return nil, errors.New("token not verified — verify it first")
	}
	token := m.cfg.Token
	m.mu.Unlock()
	return m.listZones(ctx, token)
}

// SetCustomDomain validates that the given zone is reachable with the
// current token and persists the M1 binding config. Subsequent
// DeployWorker calls will create a route+DNS pair on this zone in
// addition to the workers.dev path. Existing deployments are not
// re-bound — re-deploy them to pick up the change.
func (m *Manager) SetCustomDomain(ctx context.Context, zoneID, subdomain string) (State, error) {
	zoneID = strings.TrimSpace(zoneID)
	subdomain = strings.TrimSpace(subdomain)
	if zoneID == "" {
		return m.State(), errors.New("zone id required")
	}
	if subdomain == "" {
		return m.State(), errors.New("subdomain required (e.g. \"relay\")")
	}
	if err := validateDNSLabel(subdomain); err != nil {
		return m.State(), err
	}

	m.mu.Lock()
	if strings.TrimSpace(m.cfg.AccountID) == "" {
		m.mu.Unlock()
		return m.State(), errors.New("token not verified — verify it first")
	}
	token := m.cfg.Token
	accountID := m.cfg.AccountID
	m.mu.Unlock()

	// Fail-fast probe: verify the token can actually use Workers Custom
	// Domains on the verified account *before* persisting the binding
	// config. Catches the most common missed-scope case at save time
	// instead of at first deploy. listZones is account-filtered too, so
	// multi-account tokens can't accidentally bind a zone from another
	// account.
	if err := m.probeCustomDomainScope(ctx, token, accountID); err != nil {
		m.setLastError(err.Error())
		return m.State(), err
	}

	zones, err := m.listZones(ctx, token)
	if err != nil {
		m.setLastError(fmt.Sprintf("validating zone: %v", err))
		return m.State(), err
	}
	var matched *Zone
	for i := range zones {
		if zones[i].ID == zoneID {
			matched = &zones[i]
			break
		}
	}
	if matched == nil {
		err := fmt.Errorf(
			"zone %s not found in account %s (or not active) — pick a zone from this account, or re-verify with a token covering the intended account",
			zoneID, accountID,
		)
		m.setLastError(err.Error())
		return m.State(), err
	}

	m.mu.Lock()
	m.cfg.CustomDomain = &CustomDomain{
		ZoneID:    matched.ID,
		ZoneName:  matched.Name,
		Subdomain: subdomain,
	}
	m.lastError = ""
	if err := m.saveConfigLocked(); err != nil {
		m.lastError = fmt.Sprintf("custom domain set, but failed to persist: %v", err)
	}
	state := m.snapshotLocked()
	m.mu.Unlock()
	return state, nil
}

// ClearCustomDomain wipes the M1 binding config. Existing deployments keep
// their custom-domain bindings (and remember zone+route ids on disk) so
// DeleteWorker can still clean up — only future deploys revert to
// workers.dev only.
func (m *Manager) ClearCustomDomain() (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cfg.CustomDomain = nil
	m.lastError = ""
	if err := m.saveConfigLocked(); err != nil {
		m.lastError = fmt.Sprintf("custom domain cleared, but failed to persist: %v", err)
		return m.snapshotLocked(), err
	}
	return m.snapshotLocked(), nil
}

// legacyDeleteWorkerRoute / legacyDeleteDNSRecord clean up persisted state
// from the pre-Workers-Custom-Domains M1 implementation. Kept private and
// well-marked to avoid being conflated with current path. New deploys
// never produce records that need these.
func (m *Manager) legacyDeleteWorkerRoute(ctx context.Context, token, zoneID, routeID string) error {
	if zoneID == "" || routeID == "" {
		return nil
	}
	target := fmt.Sprintf("%s/%s/workers/routes/%s", zonesEndpoint, zoneID, routeID)
	_, status, err := m.cfDelete(ctx, token, target)
	if err != nil {
		return err
	}
	if status >= 400 && status != http.StatusNotFound {
		return fmt.Errorf("legacy delete route HTTP %d", status)
	}
	return nil
}

func (m *Manager) legacyDeleteDNSRecord(ctx context.Context, token, zoneID, recordID string) error {
	if zoneID == "" || recordID == "" {
		return nil
	}
	target := fmt.Sprintf("%s/%s/dns_records/%s", zonesEndpoint, zoneID, recordID)
	_, status, err := m.cfDelete(ctx, token, target)
	if err != nil {
		return err
	}
	if status >= 400 && status != http.StatusNotFound {
		return fmt.Errorf("legacy delete dns HTTP %d", status)
	}
	return nil
}

// --- internal helpers ---

func (m *Manager) configPath() string      { return filepath.Join(m.basePath, configFileRel) }
func (m *Manager) deploymentsPath() string { return filepath.Join(m.basePath, deploymentsFileRel) }

func (m *Manager) load() {
	if data, err := os.ReadFile(m.configPath()); err == nil && len(data) > 0 {
		_ = json.Unmarshal(data, &m.cfg)
	}
	if data, err := os.ReadFile(m.deploymentsPath()); err == nil && len(data) > 0 {
		_ = json.Unmarshal(data, &m.deployments)
	}
	if m.deployments == nil {
		m.deployments = map[string]*Deployment{}
	}
	// Resume readiness probes for any deployment not yet Active — both
	// "pending" and "failed". Treating "failed" as terminal stranded
	// otherwise-correct deploys: the one-shot probe budget routinely
	// expired before CF finished issuing the managed cert for a new
	// custom hostname (5–15 min is normal) or before a freshly-booted VPS
	// opened its relay port, and nothing ever retried — so the node was
	// left advertising a custom host that 404/522s forever. Re-probing
	// "failed" on every launch lets it self-heal once CF/VPS settle; the
	// extended per-pass budget (see probeCustomHostReadiness) plus this
	// per-launch resume keeps the probe noise bounded.
	for nodeID, dep := range m.deployments {
		if dep == nil || dep.CustomHost == "" {
			continue
		}
		if dep.CustomHostStatus == customHostStatusPending ||
			dep.CustomHostStatus == customHostStatusFailed {
			// Reset a stale "failed" to "pending" so callers see an honest
			// in-progress status during the retry.
			if dep.CustomHostStatus == customHostStatusFailed {
				m.markCustomHostStatus(nodeID, dep.CustomHost, customHostStatusPending)
			}
			go m.probeCustomHostReadiness(nodeID, dep.CustomHost)
		}
	}
}

func (m *Manager) saveConfigLocked() error {
	if err := os.MkdirAll(filepath.Dir(m.configPath()), 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(m.cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(m.configPath(), data, 0o600)
}

func (m *Manager) saveDeploymentsLocked() error {
	if err := os.MkdirAll(filepath.Dir(m.deploymentsPath()), 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(m.deployments, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(m.deploymentsPath(), data, 0o600)
}

func (m *Manager) setLastError(msg string) {
	m.mu.Lock()
	m.lastError = msg
	m.mu.Unlock()
}

func (m *Manager) cfGetJSON(ctx context.Context, token, url string) (map[string]any, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	body, err := readJSONBody(resp)
	return body, resp.StatusCode, err
}

func readJSONBody(resp *http.Response) (map[string]any, error) {
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return map[string]any{}, nil
	}
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return out, nil
}

func cfSuccess(body map[string]any) bool {
	if body == nil {
		return false
	}
	v, _ := body["success"].(bool)
	return v
}

func extractCfError(body map[string]any) string {
	if body == nil {
		return ""
	}
	errs, _ := body["errors"].([]any)
	if len(errs) == 0 {
		return ""
	}
	first, _ := errs[0].(map[string]any)
	msg, _ := first["message"].(string)
	if msg == "" {
		return ""
	}
	if code, ok := first["code"]; ok {
		return fmt.Sprintf("%s (code %v)", msg, code)
	}
	return msg
}

var nonAlnum = regexp.MustCompile(`[^a-z0-9]+`)
var dashRun = regexp.MustCompile(`-+`)

func safeWorkerName(nodeID, label string) string {
	clean := strings.ToLower(strings.TrimSpace(label))
	clean = nonAlnum.ReplaceAllString(clean, "-")
	clean = dashRun.ReplaceAllString(clean, "-")
	clean = strings.Trim(clean, "-")
	if len(clean) > 20 {
		clean = clean[:20]
	}
	short := shortHash(nodeID, 6)
	name := "pd-relay-" + short
	if clean != "" {
		name = "pd-relay-" + clean + "-" + short
	}
	if name != "" && name[0] >= '0' && name[0] <= '9' {
		name = "r-" + name
	}
	return name
}

func shortHash(s string, length int) string {
	sum := sha256.Sum256([]byte(s))
	hexed := hex.EncodeToString(sum[:])
	if length > len(hexed) {
		length = len(hexed)
	}
	return hexed[:length]
}

func escapeJSString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `'`, `\'`)
	return s
}

// randomHex returns a hex-encoded random string of length 2*nBytes drawn
// from crypto/rand. Used for the per-deployment Worker path secret —
// caller picks nBytes based on entropy budget (16 = 128 bits, plenty for
// a path token that lives in a TLS query string and rotates per redeploy).
func randomHex(nBytes int) (string, error) {
	buf := make([]byte, nBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// validateDNSLabel enforces RFC 1035 DNS label rules tightened for the
// CDN subdomain field: lowercase [a-z0-9-], 1-56 chars (leaves room for
// the "-<6hex>" suffix inside the 63-char total label budget), no
// leading/trailing hyphen. Returns nil when the label is acceptable.
func validateDNSLabel(label string) error {
	if label == "" {
		return errors.New("subdomain required")
	}
	// 56 = 63 (DNS label max) - 1 (separator '-') - 6 (script-hash suffix).
	if len(label) > 56 {
		return errors.New("subdomain too long (max 56 chars; needs room for the per-node hash suffix)")
	}
	if label[0] == '-' || label[len(label)-1] == '-' {
		return errors.New("subdomain cannot start or end with '-'")
	}
	for i := 0; i < len(label); i++ {
		c := label[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			return errors.New("subdomain must be lowercase a-z, 0-9, or '-'")
		}
	}
	return nil
}
