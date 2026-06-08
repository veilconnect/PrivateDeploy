// M1: bind the same Worker script to a user-owned domain on a Cloudflare
// zone via the Workers Custom Domains API. workers.dev itself is fingerprinted
// (and DNS-poisoned) on some CN cellular networks; serving the Worker from a
// personal domain (e.g. relay.example.com) defeats the host-based pattern
// match without changing the relay protocol.
//
// We use Cloudflare's Workers Custom Domains endpoint
// (PUT /accounts/{aid}/workers/domains) rather than the older route+CNAME
// approach. Custom Domains is the right semantic here — the Worker IS the
// origin — and CF auto-creates DNS + a managed cert behind the scenes. Two
// concrete UX wins fall out:
//
//  1. Required token scopes drop from five to three: only
//     `Account.Workers Scripts:Edit` + `Account.Account Settings:Read` +
//     `Zone.Zone:Read` (the last only needed for the zone picker; the
//     attach/detach calls themselves are pure Account-scope). The two
//     scopes users most often forget — Zone.DNS:Edit and
//     Zone.Workers Routes:Edit — are no longer required at all.
//  2. DELETE on the custom domain cascades to the auto-created DNS
//     record, so cleanup is one call instead of three.
package cdn

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"bytes"
	"encoding/json"
)

const (
	zonesEndpoint   = "https://api.cloudflare.com/client/v4/zones"
	domainsEndpoint = "https://api.cloudflare.com/client/v4/accounts/%s/workers/domains"
)

// Zone is the public summary returned to the UI for the zone picker.
type Zone struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Status string `json:"status,omitempty"`
}

// CustomDomain captures the global "deploy Workers to a user-owned domain"
// configuration. Set via SetCustomDomain; nil/empty means M1 is off and only
// workers.dev is used.
type CustomDomain struct {
	ZoneID    string `json:"zoneId,omitempty"`
	ZoneName  string `json:"zoneName,omitempty"`
	Subdomain string `json:"subdomain,omitempty"`
}

// IsSet returns true when all three fields are populated and the config is
// usable for binding.
func (c *CustomDomain) IsSet() bool {
	if c == nil {
		return false
	}
	return strings.TrimSpace(c.ZoneID) != "" &&
		strings.TrimSpace(c.ZoneName) != "" &&
		strings.TrimSpace(c.Subdomain) != ""
}

// hostForScript returns the per-script FQDN this config produces (e.g.
// "relay-3db67e.example.com"). The 6-char suffix is the same hash
// safeWorkerName already appends to scriptName, so each node gets a
// stable, distinct host. Multi-node deploys would otherwise collide on
// one hostname (CF Workers Custom Domains binds each host to exactly
// one script).
func (c *CustomDomain) hostForScript(scriptName string) string {
	if !c.IsSet() {
		return ""
	}
	sub := strings.TrimSpace(c.Subdomain)
	zone := strings.TrimSpace(c.ZoneName)
	suffix := scriptShortSuffix(scriptName)
	if suffix == "" {
		// Fail-closed: a hand-crafted scriptName without the standard
		// 6-hex tail can't be turned into a stable, DNS-legal hostname,
		// so we refuse to bind a Custom Domain. Caller treats "" as
		// "no customHost" and falls back to workers.dev.
		return ""
	}
	return fmt.Sprintf("%s-%s.%s", sub, suffix, zone)
}

// scriptShortSuffix extracts the trailing 6-hex-digit hash that
// safeWorkerName always appends to script names (see shortHash). Same
// script → same host, so re-deploys are stable.
func scriptShortSuffix(scriptName string) string {
	if len(scriptName) < 6 {
		return ""
	}
	cand := scriptName[len(scriptName)-6:]
	for i := 0; i < len(cand); i++ {
		c := cand[i]
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
		if !ok {
			return ""
		}
	}
	return cand
}

// workerCustomDomainBinding is the result of a successful attachWorkerCustomDomain.
// We persist ID on the Deployment so a later detach call addresses the exact
// binding without needing to re-resolve by hostname.
type workerCustomDomainBinding struct {
	ID       string
	Hostname string
}

// listZones runs GET /zones?account.id=<verifiedAccountID> and returns the
// active zones the token can see *in the verified account*. Filtering on
// the account matters for tokens that span multiple Cloudflare accounts:
// without it the picker offers zones from accounts the user didn't intend
// to bind, and a later attach against the "wrong" account/zone pair
// silently 404s.
//
// Walks every page of the paginated response. Earlier code stopped at the
// first 50 zones, which silently hid the rest from the picker — users
// with >50 zones couldn't pick the one they wanted. Caps at
// listZonesMaxPages to bound worst-case latency / memory if a token has
// thousands of zones.
func (m *Manager) listZones(ctx context.Context, token string) ([]Zone, error) {
	m.mu.Lock()
	accountID := strings.TrimSpace(m.cfg.AccountID)
	m.mu.Unlock()
	const perPage = 50
	const listZonesMaxPages = 40 // safety cap: 40 * 50 = 2000 zones
	zones := make([]Zone, 0, perPage)
	for page := 1; page <= listZonesMaxPages; page++ {
		url := fmt.Sprintf("%s?per_page=%d&page=%d", zonesEndpoint, perPage, page)
		if accountID != "" {
			url += "&account.id=" + accountID
		}
		body, status, err := m.cfGetJSON(ctx, token, url)
		if err != nil {
			return nil, fmt.Errorf("listing zones: %w", err)
		}
		if status != http.StatusOK || !cfSuccess(body) {
			msg := extractCfError(body)
			if msg == "" {
				msg = fmt.Sprintf("listing zones failed (HTTP %d)", status)
			}
			return nil, errors.New(msg)
		}
		raw, _ := body["result"].([]any)
		for _, item := range raw {
			obj, _ := item.(map[string]any)
			if obj == nil {
				continue
			}
			st, _ := obj["status"].(string)
			if st != "active" {
				continue
			}
			id, _ := obj["id"].(string)
			name, _ := obj["name"].(string)
			if id == "" || name == "" {
				continue
			}
			zones = append(zones, Zone{ID: id, Name: name, Status: st})
		}
		// Stop when we've drained every page. CF reports total pages in
		// result_info.total_pages; fall back to short-page detection so a
		// missing/zero total_pages (e.g. older API) still terminates.
		info, _ := body["result_info"].(map[string]any)
		totalPages := 0
		switch v := info["total_pages"].(type) {
		case float64:
			totalPages = int(v)
		case int:
			totalPages = v
		}
		if totalPages > 0 && page >= totalPages {
			break
		}
		if len(raw) < perPage {
			break
		}
	}
	return zones, nil
}

// attachWorkerCustomDomain binds hostname → script via the Workers Custom
// Domains API. CF auto-creates the DNS record and the managed cert; the
// returned id lets us detach later without re-resolving by hostname.
//
// Idempotency note: if a binding already exists for the same hostname →
// same script, CF returns 200 with the existing id (no error). If a
// hostname is bound to a *different* script, CF returns an error and we
// surface it; the user has to detach the conflicting binding first.
func (m *Manager) attachWorkerCustomDomain(ctx context.Context, token, accountID, hostname, script, zoneID string) (*workerCustomDomainBinding, error) {
	target := fmt.Sprintf(domainsEndpoint, accountID)
	payload := map[string]any{
		"hostname":    hostname,
		"service":     script,
		"environment": "production",
		"zone_id":     zoneID,
	}
	body, status, err := m.cfJSONRequest(ctx, http.MethodPut, token, target, payload)
	if err != nil {
		return nil, fmt.Errorf("attaching worker domain: %w", err)
	}
	if status >= 400 || !cfSuccess(body) {
		msg := extractCfError(body)
		if msg == "" {
			msg = fmt.Sprintf("attach worker domain failed (HTTP %d)", status)
		}
		return nil, errors.New(msg)
	}
	res, _ := body["result"].(map[string]any)
	id, _ := res["id"].(string)
	if id == "" {
		return nil, errors.New("worker domain attached but no id returned")
	}
	host, _ := res["hostname"].(string)
	if host == "" {
		host = hostname
	}
	return &workerCustomDomainBinding{ID: id, Hostname: host}, nil
}

// probeCustomDomainScope verifies the token can read the Workers Custom
// Domains endpoint on the verified account. We GET ?per_page=1 — empty
// result is fine (we just want to know that the call is permitted), but
// 401/403/9109 means the token's permission set is missing
// "Workers Scripts:Edit" against this account, so SetCustomDomain should
// stop early with a clear, actionable error instead of waiting for the
// per-script attach to fail mysteriously at deploy time.
func (m *Manager) probeCustomDomainScope(ctx context.Context, token, accountID string) error {
	target := fmt.Sprintf(domainsEndpoint+"?per_page=1", accountID)
	body, status, err := m.cfGetJSON(ctx, token, target)
	if err != nil {
		return fmt.Errorf("probing Custom Domains scope: %w", err)
	}
	if status == http.StatusOK && cfSuccess(body) {
		return nil
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return errors.New(
			"token cannot read Workers Custom Domains on this account — " +
				"add 'Account.Workers Scripts:Edit' scope to the token " +
				"(or pick a token already verified against the right account)",
		)
	}
	msg := extractCfError(body)
	if msg == "" {
		msg = fmt.Sprintf("Custom Domains scope probe failed (HTTP %d)", status)
	}
	return errors.New(msg)
}

// detachWorkerCustomDomain removes the binding by id. Best-effort: 404 is
// treated as success (binding already gone — CF dashboard or another tool
// may have removed it). The associated CF DNS record is removed by CF as
// part of the detach.
func (m *Manager) detachWorkerCustomDomain(ctx context.Context, token, accountID, domainID string) error {
	if domainID == "" {
		return nil
	}
	target := fmt.Sprintf(domainsEndpoint+"/%s", accountID, domainID)
	_, status, err := m.cfDelete(ctx, token, target)
	if err != nil {
		return err
	}
	if status >= 400 && status != http.StatusNotFound {
		return fmt.Errorf("detach worker domain HTTP %d", status)
	}
	return nil
}

// cfJSONRequest is a generic POST/PUT/PATCH for the CF API. We can't reuse
// cfGetJSON because that one builds a GET; everything else needs a body.
func (m *Manager) cfJSONRequest(ctx context.Context, method, token, target string, payload any) (map[string]any, int, error) {
	buf, err := json.Marshal(payload)
	if err != nil {
		return nil, 0, err
	}
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(buf))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	body, err := readJSONBody(resp)
	return body, resp.StatusCode, err
}

func (m *Manager) cfDelete(ctx context.Context, token, target string) (map[string]any, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, target, nil)
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
