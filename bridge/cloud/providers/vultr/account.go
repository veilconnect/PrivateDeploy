package vultr

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"privatedeploy/bridge/cloud"
)

// vultrFirewallGroupCap is the documented account-level cap on the total number
// of firewall groups for a Vultr account. Hitting it causes /firewalls POST to
// return HTTP 400 "Maximum firewall groups exceeded". Vultr does not expose the
// cap or current usage in any other endpoint, so we count groups against this
// constant client-side.
const vultrFirewallGroupCap = 50

// vultrFirewallWarnThreshold is the count at which we surface a yellow banner
// telling the operator the cap is in reach. Tuned conservatively so the user
// has a window to prune unused groups before a deploy fails outright.
const vultrFirewallWarnThreshold = 45

// GetAccountStatus probes Vultr-specific quotas that block deploys. Today this
// covers only the firewall-group cap (the most common failure mode in
// production); other quotas can be folded in here as they surface.
//
// The mapping into [cloud.AccountStatus] follows the same convention as the
// DigitalOcean provider:
//
//   - "active"      — comfortably under quota.
//   - "warning"     — over [vultrFirewallWarnThreshold] groups; a new deploy
//     still has headroom for its instance-owned group.
//   - "locked"      — at or over [vultrFirewallGroupCap]; new deploys are
//     blocked because sharing a mutable group across nodes would leak rules.
//   - "invalid_key" — Vultr rejected the configured key.
//   - "unknown"     — transient probe failure; fails open to avoid freezing
//     the UI on a network blip.
func (p *Provider) GetAccountStatus(ctx context.Context) (*cloud.AccountStatus, error) {
	if _, err := p.ensureConfig(); err != nil {
		return &cloud.AccountStatus{
			State:     "invalid_key",
			Message:   "Vultr API key not configured",
			CanDeploy: false,
			CheckedAt: time.Now().UTC(),
		}, nil
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls", nil)
	if err != nil {
		return &cloud.AccountStatus{
			State:     "unknown",
			Message:   fmt.Sprintf("firewall quota probe failed: %v", err),
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	}
	defer res.Body.Close()

	switch {
	case res.StatusCode == http.StatusUnauthorized, res.StatusCode == http.StatusForbidden:
		return &cloud.AccountStatus{
			State:     "invalid_key",
			Message:   "Vultr rejected the API key",
			CanDeploy: false,
			CheckedAt: time.Now().UTC(),
		}, nil
	case res.StatusCode >= 500:
		return &cloud.AccountStatus{
			State:     "unknown",
			Message:   fmt.Sprintf("Vultr returned HTTP %d", res.StatusCode),
			CanDeploy: true,
			CheckedAt: time.Now().UTC(),
		}, nil
	}

	var listPayload struct {
		FirewallGroups []vultrFirewallGroup `json:"firewall_groups"`
	}
	if err := p.parseResponse(res, &listPayload); err != nil {
		return nil, fmt.Errorf("failed to parse firewall groups: %w", err)
	}

	total := len(listPayload.FirewallGroups)
	return classifyVultrFirewallQuota(total), nil
}

// classifyVultrFirewallQuota turns a snapshot of firewall-group counts into a
// provider-agnostic [cloud.AccountStatus]. Split out for unit-testing without
// stubbing the HTTP client.
func classifyVultrFirewallQuota(total int) *cloud.AccountStatus {
	now := time.Now().UTC()
	switch {
	case total >= vultrFirewallGroupCap:
		return &cloud.AccountStatus{
			State: "locked",
			Message: fmt.Sprintf(
				"Vultr firewall-group cap reached (%d/%d). Each new node requires an isolated firewall group; delete an unused group before deploying.",
				total, vultrFirewallGroupCap,
			),
			CanDeploy: false,
			CheckedAt: now,
		}
	case total >= vultrFirewallWarnThreshold:
		return &cloud.AccountStatus{
			State: "warning",
			Message: fmt.Sprintf(
				"Vultr firewall groups are approaching the per-account cap (%d/%d). Consider deleting unused groups in the Vultr console before the next deploy.",
				total, vultrFirewallGroupCap,
			),
			CanDeploy: true,
			CheckedAt: now,
		}
	default:
		return &cloud.AccountStatus{
			State:     "active",
			CanDeploy: true,
			CheckedAt: now,
		}
	}
}
