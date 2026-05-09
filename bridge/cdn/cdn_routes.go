// M1: bind the same Worker script to a user-owned domain on a Cloudflare
// zone. workers.dev is selectively throttled by some regional mobile network middleboxes
// because it's a known proxy-traffic suffix; serving the Worker from a
// personal domain (e.g. relay.example.com) defeats the host-based pattern
// match without changing the relay protocol.
//
// Three CF endpoints are involved:
//   - GET /zones                                  — let the user pick a zone
//   - POST /zones/{id}/dns_records (CNAME)        — relay.example.com →
//                                                   <script>.<sub>.workers.dev
//   - POST /zones/{id}/workers/routes             — relay.example.com/* →
//                                                   <script>
//
// Each is "find-or-create": a re-deploy of the same node should not error on
// existing records. The Deployment record stores the resulting RouteID and
// DNSRecordID so DeleteWorker can clean both up before removing the script.
package cdn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

const zonesEndpoint = "https://api.cloudflare.com/client/v4/zones"

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

// hostFor returns the FQDN this config produces (e.g. "relay.example.com").
func (c *CustomDomain) hostFor() string {
	if !c.IsSet() {
		return ""
	}
	return strings.TrimSpace(c.Subdomain) + "." + strings.TrimSpace(c.ZoneName)
}

// listZones runs GET /zones and returns the active zones the token can see.
// Inactive/pending zones are filtered out — they can't host Worker routes.
func (m *Manager) listZones(ctx context.Context, token string) ([]Zone, error) {
	body, status, err := m.cfGetJSON(ctx, token, zonesEndpoint+"?per_page=50")
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
	zones := make([]Zone, 0, len(raw))
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
	return zones, nil
}

// findOrCreateDNSCNAME ensures host CNAMEs to target on zoneID, proxied
// through CF (the orange cloud — required for a Worker route to fire).
// Returns the DNS record ID. Idempotent: re-runs return the existing record
// if its content already matches; mismatched content is repaired in place
// (PATCH) so we don't leak stale records.
func (m *Manager) findOrCreateDNSCNAME(ctx context.Context, token, zoneID, host, target string) (string, error) {
	listURL := fmt.Sprintf("%s/%s/dns_records?type=CNAME&name=%s", zonesEndpoint, zoneID, url.QueryEscape(host))
	body, status, err := m.cfGetJSON(ctx, token, listURL)
	if err != nil {
		return "", fmt.Errorf("listing DNS records: %w", err)
	}
	if status != http.StatusOK || !cfSuccess(body) {
		msg := extractCfError(body)
		if msg == "" {
			msg = fmt.Sprintf("listing DNS records failed (HTTP %d)", status)
		}
		return "", errors.New(msg)
	}
	results, _ := body["result"].([]any)
	for _, r := range results {
		rec, _ := r.(map[string]any)
		if rec == nil {
			continue
		}
		id, _ := rec["id"].(string)
		content, _ := rec["content"].(string)
		proxied, _ := rec["proxied"].(bool)
		if id == "" {
			continue
		}
		if content == target && proxied {
			return id, nil
		}
		// Same host, different content/proxy state → PATCH to align.
		patchURL := fmt.Sprintf("%s/%s/dns_records/%s", zonesEndpoint, zoneID, id)
		payload := map[string]any{
			"type":    "CNAME",
			"name":    host,
			"content": target,
			"proxied": true,
			"ttl":     1,
		}
		patched, pStatus, err := m.cfJSONRequest(ctx, http.MethodPatch, token, patchURL, payload)
		if err != nil {
			return "", fmt.Errorf("patching DNS record %s: %w", id, err)
		}
		if pStatus >= 400 || !cfSuccess(patched) {
			msg := extractCfError(patched)
			if msg == "" {
				msg = fmt.Sprintf("patching DNS record failed (HTTP %d)", pStatus)
			}
			return "", errors.New(msg)
		}
		return id, nil
	}

	// No existing record — create one.
	createURL := fmt.Sprintf("%s/%s/dns_records", zonesEndpoint, zoneID)
	payload := map[string]any{
		"type":    "CNAME",
		"name":    host,
		"content": target,
		"proxied": true,
		"ttl":     1,
	}
	created, cStatus, err := m.cfJSONRequest(ctx, http.MethodPost, token, createURL, payload)
	if err != nil {
		return "", fmt.Errorf("creating DNS record: %w", err)
	}
	if cStatus >= 400 || !cfSuccess(created) {
		msg := extractCfError(created)
		if msg == "" {
			msg = fmt.Sprintf("creating DNS record failed (HTTP %d)", cStatus)
		}
		return "", errors.New(msg)
	}
	res, _ := created["result"].(map[string]any)
	id, _ := res["id"].(string)
	if id == "" {
		return "", errors.New("DNS record created but no id returned")
	}
	return id, nil
}

// findOrCreateWorkerRoute ensures pattern → script on zoneID. Idempotent:
// listing first lets us reuse an existing route id and avoid the
// "route already exists" 400. Mismatched script bindings (same pattern,
// different script) are repaired via PUT.
func (m *Manager) findOrCreateWorkerRoute(ctx context.Context, token, zoneID, pattern, script string) (string, error) {
	listURL := fmt.Sprintf("%s/%s/workers/routes", zonesEndpoint, zoneID)
	body, status, err := m.cfGetJSON(ctx, token, listURL)
	if err != nil {
		return "", fmt.Errorf("listing worker routes: %w", err)
	}
	if status != http.StatusOK || !cfSuccess(body) {
		msg := extractCfError(body)
		if msg == "" {
			msg = fmt.Sprintf("listing worker routes failed (HTTP %d)", status)
		}
		return "", errors.New(msg)
	}
	results, _ := body["result"].([]any)
	for _, r := range results {
		rec, _ := r.(map[string]any)
		if rec == nil {
			continue
		}
		id, _ := rec["id"].(string)
		p, _ := rec["pattern"].(string)
		s, _ := rec["script"].(string)
		if id == "" || p != pattern {
			continue
		}
		if s == script {
			return id, nil
		}
		// Same pattern, different script — repair.
		putURL := fmt.Sprintf("%s/%s/workers/routes/%s", zonesEndpoint, zoneID, id)
		payload := map[string]any{"pattern": pattern, "script": script}
		fixed, pStatus, err := m.cfJSONRequest(ctx, http.MethodPut, token, putURL, payload)
		if err != nil {
			return "", fmt.Errorf("updating worker route %s: %w", id, err)
		}
		if pStatus >= 400 || !cfSuccess(fixed) {
			msg := extractCfError(fixed)
			if msg == "" {
				msg = fmt.Sprintf("updating worker route failed (HTTP %d)", pStatus)
			}
			return "", errors.New(msg)
		}
		return id, nil
	}

	createURL := fmt.Sprintf("%s/%s/workers/routes", zonesEndpoint, zoneID)
	payload := map[string]any{"pattern": pattern, "script": script}
	created, cStatus, err := m.cfJSONRequest(ctx, http.MethodPost, token, createURL, payload)
	if err != nil {
		return "", fmt.Errorf("creating worker route: %w", err)
	}
	if cStatus >= 400 || !cfSuccess(created) {
		msg := extractCfError(created)
		if msg == "" {
			msg = fmt.Sprintf("creating worker route failed (HTTP %d)", cStatus)
		}
		return "", errors.New(msg)
	}
	res, _ := created["result"].(map[string]any)
	id, _ := res["id"].(string)
	if id == "" {
		return "", errors.New("worker route created but no id returned")
	}
	return id, nil
}

// deleteWorkerRoute is best-effort: 404 means the route was already gone.
func (m *Manager) deleteWorkerRoute(ctx context.Context, token, zoneID, routeID string) error {
	if zoneID == "" || routeID == "" {
		return nil
	}
	deleteURL := fmt.Sprintf("%s/%s/workers/routes/%s", zonesEndpoint, zoneID, routeID)
	_, status, err := m.cfDelete(ctx, token, deleteURL)
	if err != nil {
		return err
	}
	if status >= 400 && status != http.StatusNotFound {
		return fmt.Errorf("delete route HTTP %d", status)
	}
	return nil
}

// deleteDNSRecord is best-effort: 404 is treated as success.
func (m *Manager) deleteDNSRecord(ctx context.Context, token, zoneID, recordID string) error {
	if zoneID == "" || recordID == "" {
		return nil
	}
	deleteURL := fmt.Sprintf("%s/%s/dns_records/%s", zonesEndpoint, zoneID, recordID)
	_, status, err := m.cfDelete(ctx, token, deleteURL)
	if err != nil {
		return err
	}
	if status >= 400 && status != http.StatusNotFound {
		return fmt.Errorf("delete dns HTTP %d", status)
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
