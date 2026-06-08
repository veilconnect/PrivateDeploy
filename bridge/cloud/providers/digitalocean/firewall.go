package digitalocean

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

// ensurePrivateDeployFirewall finds (or creates) a protocol-specific firewall
// for the given port assignment and returns its ID.
func (p *Provider) ensurePrivateDeployFirewall(ctx context.Context, ports deploy.PortAssignment) (string, error) {
	// Include vlessRelayPort in the name so distinct port profiles get
	// distinct firewalls (avoids accidentally sharing one firewall across
	// nodes that have different relay-port allocations).
	firewallName := fmt.Sprintf("privatedeploy-%d-%d-%d-%d-%d",
		ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort,
		ports.VLESSRelayPort)

	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/firewalls", nil)
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var listResult struct {
		Firewalls []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"firewalls"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&listResult); err != nil {
		return "", err
	}

	for _, fw := range listResult.Firewalls {
		if fw.Name == firewallName {
			return fw.ID, nil
		}
	}

	firewallReq := map[string]interface{}{
		"name": firewallName,
		"inbound_rules": []map[string]interface{}{
			{
				"protocol": "tcp",
				"ports":    "22",
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.SSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    fmt.Sprintf("%d", ports.SSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    fmt.Sprintf("%d", ports.HysteriaPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.VLESSPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.TrojanPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "tcp",
				"ports":    fmt.Sprintf("%d", ports.VLESSRelayPort),
				"sources": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
		},
		"outbound_rules": []map[string]interface{}{
			{
				"protocol": "tcp",
				"ports":    "all",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "udp",
				"ports":    "all",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
			{
				"protocol": "icmp",
				"destinations": map[string]interface{}{
					"addresses": []string{"0.0.0.0/0", "::/0"},
				},
			},
		},
	}

	reqBody, err := json.Marshal(firewallReq)
	if err != nil {
		return "", fmt.Errorf("failed to marshal firewall request: %w", err)
	}

	createReq, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/firewalls", bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}

	createReq.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	createReq.Header.Set("Content-Type", "application/json")

	createResp, err := p.client.Do(createReq)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer createResp.Body.Close()

	if createResp.StatusCode != http.StatusCreated && createResp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(createResp.Body)
		return "", fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, createResp.StatusCode, string(body))
	}

	var createResult struct {
		Firewall struct {
			ID string `json:"id"`
		} `json:"firewall"`
	}

	if err := json.NewDecoder(createResp.Body).Decode(&createResult); err != nil {
		return "", fmt.Errorf("failed to decode firewall creation response: %w", err)
	}

	return createResult.Firewall.ID, nil
}

// associateFirewallWithDroplet attaches a firewall to a droplet.
func (p *Provider) associateFirewallWithDroplet(ctx context.Context, firewallID string, dropletID int) error {
	reqBody := map[string]interface{}{
		"droplet_ids": []int{dropletID},
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/firewalls/"+firewallID+"/droplets", bytes.NewReader(body))
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(respBody))
	}

	return nil
}
