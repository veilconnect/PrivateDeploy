// M1: bind the same Worker script to a user-owned domain on a Cloudflare
// zone via the Workers Custom Domains API. workers.dev itself is fingerprinted
// (and DNS-altered) on some regional mobile network networks; serving the Worker from a
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

// hostFor returns the FQDN this config produces (e.g. "relay.example.com").
func (c *CustomDomain) hostFor() string {
	if !c.IsSet() {
		return ""
	}
	return strings.TrimSpace(c.Subdomain) + "." + strings.TrimSpace(c.ZoneName)
}

// workerCustomDomainBinding is the result of a successful attachWorkerCustomDomain.
// We persist ID on the Deployment so a later detach call addresses the exact
// binding without needing to re-resolve by hostname.
type workerCustomDomainBinding struct {
	ID       string
	Hostname string
}

// listZones runs GET /zones and returns the active zones the token can see.
// Inactive/pending zones are filtered out — they can't host Worker domains.
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
