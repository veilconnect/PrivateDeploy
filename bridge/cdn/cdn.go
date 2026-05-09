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
// CustomHost / RouteID / DNSRecordID / ZoneID are populated only when M1's
// custom-domain binding has been applied. They live on the deployment (not
// just global config) so DeleteWorker can clean up route+DNS even after the
// user has changed or cleared the global CustomDomain config.
type Deployment struct {
	NodeID       string    `json:"nodeId"`
	ScriptName   string    `json:"scriptName"`
	WorkerHost   string    `json:"workerHost"`
	Backend      string    `json:"backend"`
	DeployedAt   time.Time `json:"deployedAt"`
	CustomHost   string    `json:"customHost,omitempty"`
	ZoneID       string    `json:"zoneId,omitempty"`
	RouteID      string    `json:"routeId,omitempty"`
	DNSRecordID  string    `json:"dnsRecordId,omitempty"`
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

	// Persist + announce.
	m.mu.Lock()
	m.cfg = persistedConfig{
		Token:            token,
		AccountID:        accountID,
		AccountEmail:     email,
		WorkersSubdomain: workersSub,
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

// Clear wipes all CDN state from disk.
func (m *Manager) Clear() (State, error) {
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
	if strings.TrimSpace(m.cfg.WorkersSubdomain) == "" {
		s := m.snapshotLocked()
		m.mu.Unlock()
		return s, errors.New("no workers.dev subdomain claimed yet")
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
	body := strings.ReplaceAll(
		m.workerTpl,
		`'__BACKEND_PLACEHOLDER__'`,
		fmt.Sprintf(`'%s'`, escapeJSString(backend)),
	)
	if strings.Contains(body, "__BACKEND_PLACEHOLDER__") {
		m.setLastError("worker template missing BACKEND placeholder")
		return m.State(), errors.New("worker template missing BACKEND placeholder")
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

	// Enable workers.dev subdomain for the script.
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

	host := fmt.Sprintf("%s.%s.workers.dev", scriptName, subdomain)
	dep := &Deployment{
		NodeID:     nodeID,
		ScriptName: scriptName,
		WorkerHost: host,
		Backend:    backend,
		DeployedAt: time.Now().UTC(),
	}

	// M1: if a CustomDomain is configured, also bind this Worker to a
	// route under that zone. Failure here is non-fatal — the Worker still
	// works through workers.dev. We surface the error in lastError so the
	// user can re-deploy or fix permissions, but we keep the deployment.
	customDomainCopy, _ := m.cloneCustomDomainConfig()
	customWarn := ""
	if customDomainCopy.IsSet() {
		customHost := customDomainCopy.hostFor()
		dnsTarget := host // CNAME target = the workers.dev hostname.
		dnsID, err := m.findOrCreateDNSCNAME(ctx, token, customDomainCopy.ZoneID, customHost, dnsTarget)
		if err != nil {
			customWarn = fmt.Sprintf("workers.dev path live, but custom-domain DNS step failed: %v", err)
		} else {
			pattern := customHost + "/*"
			routeID, err := m.findOrCreateWorkerRoute(ctx, token, customDomainCopy.ZoneID, pattern, scriptName)
			if err != nil {
				customWarn = fmt.Sprintf("workers.dev path live, but custom-domain route step failed: %v", err)
			} else {
				dep.CustomHost = customHost
				dep.ZoneID = customDomainCopy.ZoneID
				dep.RouteID = routeID
				dep.DNSRecordID = dnsID
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
	accountID := m.cfg.AccountID
	scriptName := dep.ScriptName
	zoneID := dep.ZoneID
	routeID := dep.RouteID
	dnsRecordID := dep.DNSRecordID
	m.mu.Unlock()

	// Tear down the M1 custom-domain bindings first. Both are best-effort:
	// 404 means the binding is already gone (CF's UI or another tool may
	// have removed it). A non-404 error is surfaced through lastError but
	// does not abort the script delete — leaving the CF Worker in place
	// while route/DNS persist would be the worst outcome.
	if routeID != "" {
		if err := m.deleteWorkerRoute(ctx, token, zoneID, routeID); err != nil {
			m.setLastError(fmt.Sprintf("worker route cleanup failed: %v", err))
		}
	}
	if dnsRecordID != "" {
		if err := m.deleteDNSRecord(ctx, token, zoneID, dnsRecordID); err != nil {
			m.setLastError(fmt.Sprintf("custom-domain DNS cleanup failed: %v", err))
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
	if strings.ContainsAny(subdomain, " ./") {
		return m.State(), errors.New("subdomain must be a single label (no '.', '/', or whitespace)")
	}

	m.mu.Lock()
	if strings.TrimSpace(m.cfg.AccountID) == "" {
		m.mu.Unlock()
		return m.State(), errors.New("token not verified — verify it first")
	}
	token := m.cfg.Token
	m.mu.Unlock()

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
		err := fmt.Errorf("zone %s not found in this account (or not active)", zoneID)
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
