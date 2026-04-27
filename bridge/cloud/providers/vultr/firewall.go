package vultr

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud/deploy"
)

// configureInstanceFirewall sets up Vultr firewall rules for the instance.
func (p *Provider) configureInstanceFirewall(ctx context.Context, instanceID string, ports deploy.PortAssignment, label string) {
	firewallID, err := p.ensureFirewallGroup(ctx, requiredFirewallRuleCount(ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort))
	if err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to ensure firewall group: %v\n", err)
		return
	}
	if err := p.ensureFirewallRules(ctx, firewallID, ports.SSPort, ports.HysteriaPort, ports.VLESSPort, ports.TrojanPort, label); err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to configure firewall rules: %v\n", err)
		return
	}
	if err := p.attachFirewallToInstance(ctx, instanceID, firewallID); err != nil {
		fmt.Printf("[VultrProvider] Warning: failed to attach firewall: %v\n", err)
	}
}

// ensureFirewallGroup gets or creates a firewall group for PrivateDeploy.
func (p *Provider) ensureFirewallGroup(ctx context.Context, requiredRules int) (string, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls", nil)
	if err != nil {
		return "", fmt.Errorf("failed to list firewall groups: %w", err)
	}

	var listPayload struct {
		FirewallGroups []vultrFirewallGroup `json:"firewall_groups"`
	}
	if err := p.parseResponse(res, &listPayload); err != nil {
		return "", fmt.Errorf("failed to parse firewall groups: %w", err)
	}

	hasPrivateDeployGroup := false
	for _, fg := range listPayload.FirewallGroups {
		if strings.Contains(fg.Description, "PrivateDeploy") {
			hasPrivateDeployGroup = true
			if firewallGroupHasCapacity(fg, requiredRules) {
				return fg.ID, nil
			}
		}
	}

	// Fall back to any existing PrivateDeploy group when the API omits capacity metadata.
	for _, fg := range listPayload.FirewallGroups {
		if strings.Contains(fg.Description, "PrivateDeploy") && fg.MaxRuleCount == 0 && fg.RuleCount == 0 {
			return fg.ID, nil
		}
	}

	description := "PrivateDeploy Auto-Managed Firewall"
	if hasPrivateDeployGroup {
		description = fmt.Sprintf("%s (%s)", description, time.Now().UTC().Format("20060102-150405"))
	}
	createPayload := map[string]any{
		"description": description,
	}

	res, err = p.apiRequest(ctx, http.MethodPost, "/firewalls", createPayload)
	if err != nil {
		return "", fmt.Errorf("failed to create firewall group: %w", err)
	}

	var createResult struct {
		FirewallGroup vultrFirewallGroup `json:"firewall_group"`
	}
	if err := p.parseResponse(res, &createResult); err != nil {
		return "", fmt.Errorf("failed to parse created firewall group: %w", err)
	}

	if err := p.addFirewallRule(ctx, createResult.FirewallGroup.ID, sshFirewallRule()); err != nil {
		return "", fmt.Errorf("failed to add SSH rule: %w", err)
	}

	return createResult.FirewallGroup.ID, nil
}

func firewallGroupHasCapacity(group vultrFirewallGroup, requiredRules int) bool {
	if requiredRules <= 0 {
		return true
	}
	if group.MaxRuleCount <= 0 {
		return false
	}
	return group.RuleCount+requiredRules <= group.MaxRuleCount
}

func requiredFirewallRuleCount(ssPort, hysteriaPort, vlessPort, trojanPort int) int {
	return len(firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort, ""))
}

func sshFirewallRule() vultrFirewallRule {
	return vultrFirewallRule{
		IPType:     "v4",
		Protocol:   "tcp",
		Subnet:     "0.0.0.0",
		SubnetSize: 0,
		Port:       "22",
		Notes:      "SSH Access",
	}
}

func firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort int, label string) []vultrFirewallRule {
	rules := []vultrFirewallRule{sshFirewallRule()}
	if ssPort > 0 {
		ssPortStr := strconv.Itoa(ssPort)
		rules = append(rules,
			vultrFirewallRule{
				IPType:     "v4",
				Protocol:   "tcp",
				Subnet:     "0.0.0.0",
				SubnetSize: 0,
				Port:       ssPortStr,
				Notes:      fmt.Sprintf("%s Shadowsocks TCP", label),
			},
			vultrFirewallRule{
				IPType:     "v4",
				Protocol:   "udp",
				Subnet:     "0.0.0.0",
				SubnetSize: 0,
				Port:       ssPortStr,
				Notes:      fmt.Sprintf("%s Shadowsocks UDP", label),
			},
		)
	}
	if hysteriaPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "udp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(hysteriaPort),
			Notes:      fmt.Sprintf("%s Hysteria2", label),
		})
	}
	if vlessPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "tcp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(vlessPort),
			Notes:      fmt.Sprintf("%s VLESS", label),
		})
	}
	if trojanPort > 0 {
		rules = append(rules, vultrFirewallRule{
			IPType:     "v4",
			Protocol:   "tcp",
			Subnet:     "0.0.0.0",
			SubnetSize: 0,
			Port:       strconv.Itoa(trojanPort),
			Notes:      fmt.Sprintf("%s Trojan", label),
		})
	}
	return rules
}

func firewallRuleKey(protocol, port string) string {
	return fmt.Sprintf("%s:%s", protocol, port)
}

func (p *Provider) addFirewallRule(ctx context.Context, firewallID string, rule vultrFirewallRule) error {
	res, err := p.apiRequest(ctx, http.MethodPost, "/firewalls/"+firewallID+"/rules", rule)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	if res.StatusCode >= 400 {
		body, _ := io.ReadAll(res.Body)
		return fmt.Errorf("failed to add firewall rule: %s", decodeVultrError(body))
	}

	return nil
}

func (p *Provider) ensureFirewallRules(ctx context.Context, firewallID string, ssPort, hysteriaPort, vlessPort, trojanPort int, label string) error {
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls/"+firewallID+"/rules", nil)
	if err != nil {
		return fmt.Errorf("failed to list firewall rules: %w", err)
	}

	var listPayload struct {
		FirewallRules []vultrFirewallRule `json:"firewall_rules"`
	}
	if err := p.parseResponse(res, &listPayload); err != nil {
		return fmt.Errorf("failed to parse firewall rules: %w", err)
	}

	existingRules := make(map[string]bool)
	for _, rule := range listPayload.FirewallRules {
		existingRules[firewallRuleKey(rule.Protocol, rule.Port)] = true
	}

	for _, rule := range firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort, label) {
		if existingRules[firewallRuleKey(rule.Protocol, rule.Port)] {
			continue
		}
		if err := p.addFirewallRule(ctx, firewallID, rule); err != nil {
			return err
		}
	}

	return nil
}

func (p *Provider) attachFirewallToInstance(ctx context.Context, instanceID, firewallID string) error {
	payload := map[string]any{
		"firewall_group_id": firewallID,
	}

	res, err := p.apiRequest(ctx, http.MethodPatch, "/instances/"+instanceID, payload)
	if err != nil {
		return fmt.Errorf("failed to attach firewall: %w", err)
	}
	defer res.Body.Close()

	if res.StatusCode >= 400 {
		body, _ := io.ReadAll(res.Body)
		return fmt.Errorf("failed to attach firewall to instance: %s", decodeVultrError(body))
	}

	return nil
}
