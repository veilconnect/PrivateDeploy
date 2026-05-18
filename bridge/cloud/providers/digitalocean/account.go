package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

// accountResponse mirrors the DigitalOcean v2 /account payload. Only the
// fields used by the UI degrade flow are deserialized.
type accountResponse struct {
	Account struct {
		Status        string `json:"status"`
		StatusMessage string `json:"status_message"`
		EmailVerified bool   `json:"email_verified"`
		Email         string `json:"email"`
	} `json:"account"`
}

// GetAccountStatus probes GET /v2/account and maps DigitalOcean's account
// status into the provider-agnostic [cloud.AccountStatus] envelope.
//
// DigitalOcean documents status values "active", "warning", and "locked".
// HTTP 401 indicates a rejected or missing key. HTTP 5xx / network errors
// fail open (state="unknown", CanDeploy=true) so a transient upstream blip
// does not block the operator from retrying a deploy.
func (p *Provider) GetAccountStatus(ctx context.Context) (*cloud.AccountStatus, error) {
	if p.config == nil || strings.TrimSpace(p.config.APIKey) == "" {
		return &cloud.AccountStatus{
			State:     "invalid_key",
			Message:   "DigitalOcean API key not configured",
			CanDeploy: false,
			CheckedAt: time.Now().UTC(),
		}, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/account", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return &cloud.AccountStatus{
			State:     "unknown",
			Message:   fmt.Sprintf("account probe failed: %v", err),
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusUnauthorized, resp.StatusCode == http.StatusForbidden:
		return &cloud.AccountStatus{
			State:     "invalid_key",
			Message:   "DigitalOcean rejected the API key",
			CanDeploy: false,
			CheckedAt: time.Now().UTC(),
		}, nil
	case resp.StatusCode >= 500:
		return &cloud.AccountStatus{
			State:     "unknown",
			Message:   fmt.Sprintf("DigitalOcean returned HTTP %d", resp.StatusCode),
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var payload accountResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("failed to decode account payload: %w", err)
	}

	return mapDigitalOceanAccountStatus(payload), nil
}

func mapDigitalOceanAccountStatus(payload accountResponse) *cloud.AccountStatus {
	state := strings.ToLower(strings.TrimSpace(payload.Account.Status))
	message := strings.TrimSpace(payload.Account.StatusMessage)
	now := time.Now().UTC()

	switch state {
	case "active":
		return &cloud.AccountStatus{
			State:     "active",
			Message:   message,
			CanDeploy: true,
			CheckedAt: now,
		}
	case "warning":
		if message == "" {
			message = "DigitalOcean account has an unresolved warning"
		}
		return &cloud.AccountStatus{
			State:     "warning",
			Message:   message,
			CanDeploy: true,
			CheckedAt: now,
		}
	case "locked":
		if message == "" {
			message = "DigitalOcean has locked this account; new resources cannot be created until it is restored"
		}
		return &cloud.AccountStatus{
			State:     "locked",
			Message:   message,
			CanDeploy: false,
			CheckedAt: now,
		}
	default:
		if message == "" {
			message = fmt.Sprintf("Unrecognized DigitalOcean account status: %q", payload.Account.Status)
		}
		return &cloud.AccountStatus{
			State:     "unknown",
			Message:   message,
			CanDeploy: true,
			CheckedAt: now,
		}
	}
}
