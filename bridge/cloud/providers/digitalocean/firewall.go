package digitalocean

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

const managedFirewallNamePrefix = "privatedeploy-managed-"

type digitalOceanFirewall struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type digitalOceanFirewallSelection struct {
	firewall     digitalOceanFirewall
	created      bool
	duplicateIDs []string
}

func newFirewallOwnershipToken() (string, error) {
	var token [12]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", fmt.Errorf("failed to generate firewall ownership token: %w", err)
	}
	return hex.EncodeToString(token[:]), nil
}

func managedFirewallName(instanceID, token string) string {
	return managedFirewallNamePrefix + strings.TrimSpace(instanceID) + "-" + strings.TrimSpace(token)
}

func isManagedFirewallForInstance(name, instanceID, token string) bool {
	if strings.TrimSpace(token) == "" {
		return false
	}
	return strings.TrimSpace(name) == managedFirewallName(instanceID, token)
}

func (p *Provider) ensureFirewallOwnershipToken(instanceID string) (string, error) {
	var token string
	err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok {
			return false, fmt.Errorf("cannot configure firewall for unrecorded instance %s", instanceID)
		}
		token = strings.TrimSpace(record.FirewallOwnershipToken)
		if token != "" {
			return false, nil
		}
		var err error
		token, err = newFirewallOwnershipToken()
		if err != nil {
			return false, err
		}
		record.FirewallOwnershipToken = token
		records[instanceID] = record
		return true, nil
	})
	return token, err
}

func (p *Provider) rememberFirewallGroup(instanceID, token, firewallID string) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok {
			return false, fmt.Errorf("node record disappeared while configuring firewall for %s", instanceID)
		}
		if record.FirewallOwnershipToken != token {
			return false, fmt.Errorf("firewall ownership token changed while configuring %s", instanceID)
		}
		if record.FirewallGroupID == firewallID && !record.FirewallCleanupPending {
			return false, nil
		}
		record.FirewallGroupID = firewallID
		record.FirewallCleanupPending = false
		records[instanceID] = record
		return true, nil
	})
}

func (p *Provider) listFirewalls(ctx context.Context) ([]digitalOceanFirewall, error) {
	apiKey, err := p.apiKey()
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/firewalls?per_page=200", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: list firewalls status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}
	var result struct {
		Firewalls []digitalOceanFirewall `json:"firewalls"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode firewall list: %w", err)
	}
	return result.Firewalls, nil
}

func ownedFirewallSelection(firewalls []digitalOceanFirewall, instanceID, token string) (digitalOceanFirewallSelection, bool) {
	owned := make([]digitalOceanFirewall, 0, 1)
	for _, firewall := range firewalls {
		if isManagedFirewallForInstance(firewall.Name, instanceID, token) {
			owned = append(owned, firewall)
		}
	}
	if len(owned) == 0 {
		return digitalOceanFirewallSelection{}, false
	}
	sort.Slice(owned, func(i, j int) bool { return owned[i].ID < owned[j].ID })
	selection := digitalOceanFirewallSelection{firewall: owned[0]}
	for _, duplicate := range owned[1:] {
		selection.duplicateIDs = append(selection.duplicateIDs, duplicate.ID)
	}
	return selection, true
}

func digitalOceanFirewallRequest(name string, ports deploy.PortAssignment) map[string]interface{} {
	openAddresses := func() map[string]interface{} {
		return map[string]interface{}{"addresses": []string{"0.0.0.0/0", "::/0"}}
	}
	inbound := []map[string]interface{}{
		{"protocol": "tcp", "ports": "22", "sources": openAddresses()},
	}
	appendPort := func(protocol string, port int) {
		if port <= 0 {
			return
		}
		inbound = append(inbound, map[string]interface{}{
			"protocol": protocol,
			"ports":    fmt.Sprintf("%d", port),
			"sources":  openAddresses(),
		})
	}
	appendPort("tcp", ports.SSPort)
	appendPort("udp", ports.SSPort)
	appendPort("udp", ports.HysteriaPort)
	appendPort("tcp", ports.VLESSPort)
	appendPort("tcp", ports.TrojanPort)
	appendPort("tcp", ports.VLESSRelayPort)
	outbound := []map[string]interface{}{
		{"protocol": "tcp", "ports": "all", "destinations": openAddresses()},
		{"protocol": "udp", "ports": "all", "destinations": openAddresses()},
		{"protocol": "icmp", "destinations": openAddresses()},
	}
	return map[string]interface{}{
		"name":           name,
		"inbound_rules":  inbound,
		"outbound_rules": outbound,
	}
}

func (p *Provider) createFirewall(ctx context.Context, name string, ports deploy.PortAssignment) (digitalOceanFirewall, error) {
	apiKey, err := p.apiKey()
	if err != nil {
		return digitalOceanFirewall{}, err
	}
	body, err := json.Marshal(digitalOceanFirewallRequest(name, ports))
	if err != nil {
		return digitalOceanFirewall{}, fmt.Errorf("failed to marshal firewall request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/firewalls", bytes.NewReader(body))
	if err != nil {
		return digitalOceanFirewall{}, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return digitalOceanFirewall{}, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusAccepted {
		responseBody, _ := io.ReadAll(resp.Body)
		return digitalOceanFirewall{}, fmt.Errorf("%w: create firewall status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(responseBody))
	}
	var result struct {
		Firewall digitalOceanFirewall `json:"firewall"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return digitalOceanFirewall{}, fmt.Errorf("failed to decode firewall creation response: %w", err)
	}
	if strings.TrimSpace(result.Firewall.ID) == "" {
		return digitalOceanFirewall{}, fmt.Errorf("DigitalOcean returned an empty firewall id")
	}
	if result.Firewall.Name == "" {
		result.Firewall.Name = name
	}
	return result.Firewall, nil
}

func (p *Provider) ensureInstanceFirewall(ctx context.Context, instanceID string, ports deploy.PortAssignment) (digitalOceanFirewallSelection, error) {
	token, err := p.ensureFirewallOwnershipToken(instanceID)
	if err != nil {
		return digitalOceanFirewallSelection{}, err
	}
	firewalls, err := p.listFirewalls(ctx)
	if err != nil {
		return digitalOceanFirewallSelection{}, err
	}
	if selection, ok := ownedFirewallSelection(firewalls, instanceID, token); ok {
		return selection, nil
	}
	name := managedFirewallName(instanceID, token)
	firewall, createErr := p.createFirewall(ctx, name, ports)
	if createErr != nil {
		// DigitalOcean can accept a POST even when its response is lost. Read
		// back the deterministic ownership name before reporting failure.
		if recovered, listErr := p.listFirewalls(ctx); listErr == nil {
			if selection, ok := ownedFirewallSelection(recovered, instanceID, token); ok {
				return selection, nil
			}
		}
		return digitalOceanFirewallSelection{}, createErr
	}
	return digitalOceanFirewallSelection{firewall: firewall, created: true}, nil
}

func (p *Provider) configureInstanceFirewall(ctx context.Context, instanceID string, dropletID int, ports deploy.PortAssignment) error {
	digitaloceanFirewallMu.Lock()
	defer digitaloceanFirewallMu.Unlock()

	selection, err := p.ensureInstanceFirewall(ctx, instanceID, ports)
	if err != nil {
		return err
	}
	if err := p.associateFirewallWithDroplet(ctx, selection.firewall.ID, dropletID); err != nil {
		return p.rollbackNewFirewall(selection, fmt.Errorf("failed to attach firewall: %w", err))
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return p.rollbackNewFirewall(selection, fmt.Errorf("failed to reload firewall ownership: %w", err))
	}
	token := records[instanceID].FirewallOwnershipToken
	if err := p.rememberFirewallGroup(instanceID, token, selection.firewall.ID); err != nil {
		return p.rollbackNewFirewall(selection, err)
	}
	duplicateCleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, duplicateID := range selection.duplicateIDs {
		if err := p.deleteFirewall(duplicateCleanupCtx, duplicateID); err != nil {
			return fmt.Errorf("firewall configured, but duplicate managed firewall %s could not be reclaimed: %w", duplicateID, err)
		}
	}
	return nil
}

func (p *Provider) rollbackNewFirewall(selection digitalOceanFirewallSelection, cause error) error {
	if !selection.created {
		return cause
	}
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := p.deleteFirewall(cleanupCtx, selection.firewall.ID); err != nil {
		return fmt.Errorf("%v; failed to roll back new firewall %s: %w", cause, selection.firewall.ID, err)
	}
	return cause
}

// associateFirewallWithDroplet attaches a firewall to a droplet. Repeating
// the same request is idempotent in DigitalOcean's API.
func (p *Provider) associateFirewallWithDroplet(ctx context.Context, firewallID string, dropletID int) error {
	apiKey, err := p.apiKey()
	if err != nil {
		return err
	}
	body, err := json.Marshal(map[string]interface{}{"droplet_ids": []int{dropletID}})
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/firewalls/"+firewallID+"/droplets", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		responseBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(responseBody))
	}
	return nil
}

func (p *Provider) deleteFirewall(ctx context.Context, firewallID string) error {
	apiKey, err := p.apiKey()
	if err != nil {
		return err
	}
	const maxAttempts = 5
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodDelete, baseURL+"/firewalls/"+firewallID, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+apiKey)
		resp, err := p.client.Do(req)
		if err != nil {
			return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode == http.StatusNoContent || resp.StatusCode == http.StatusAccepted || resp.StatusCode == http.StatusNotFound {
			return nil
		}
		retryable := resp.StatusCode >= http.StatusInternalServerError || resp.StatusCode == http.StatusConflict || resp.StatusCode == http.StatusUnprocessableEntity
		if !retryable || attempt == maxAttempts {
			return fmt.Errorf("%w: delete firewall status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
	return nil
}

func (p *Provider) cleanupInstanceFirewalls(ctx context.Context, instanceID, token string) error {
	if strings.TrimSpace(token) == "" {
		// Fixed-port and port-named firewalls from older releases have no
		// verifiable ownership marker. They are legacy and must not be deleted.
		return nil
	}
	digitaloceanFirewallMu.Lock()
	defer digitaloceanFirewallMu.Unlock()
	firewalls, err := p.listFirewalls(ctx)
	if err != nil {
		return err
	}
	for _, firewall := range firewalls {
		if !isManagedFirewallForInstance(firewall.Name, instanceID, token) {
			continue
		}
		if err := p.deleteFirewall(ctx, firewall.ID); err != nil {
			return err
		}
	}
	return nil
}
