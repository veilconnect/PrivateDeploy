package vultr

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud/deploy"
)

const (
	// New firewall groups are deliberately one-to-one with instances. Random
	// protocol ports must never accumulate in a shared account-level group.
	managedFirewallDescriptionPrefix = "PrivateDeploy managed instance "
	legacyFirewallDescription        = "PrivateDeploy Auto-Managed Firewall"
)

type instanceFirewallGroup struct {
	group        vultrFirewallGroup
	created      bool
	legacy       bool
	duplicateIDs []string
}

// configureInstanceFirewall reconciles a deterministic, instance-owned
// firewall group and attaches it to the instance. The whole operation is
// serialized because Vultr firewall creation has no idempotency-key support.
// Calling this method repeatedly (including from repair) therefore converges
// on the same group and rules instead of consuming another quota slot.
func (p *Provider) configureInstanceFirewall(ctx context.Context, instanceID string, ports deploy.PortAssignment, label string) error {
	instanceID = strings.TrimSpace(instanceID)
	if instanceID == "" {
		return fmt.Errorf("instance id is required for firewall ownership")
	}

	firewallLifecycleMu.Lock()
	defer firewallLifecycleMu.Unlock()
	ownershipToken, err := p.ensureFirewallOwnershipToken(instanceID)
	if err != nil {
		return err
	}

	desiredRules := firewallRulesForPorts(
		ports.SSPort,
		ports.HysteriaPort,
		ports.VLESSPort,
		ports.TrojanPort,
		ports.VLESSRelayPort,
		label,
	)
	selection, err := p.ensureInstanceFirewallGroup(ctx, instanceID, ownershipToken, desiredRules)
	if err != nil {
		return fmt.Errorf("failed to ensure instance firewall group: %w", err)
	}

	// A legacy group is selected only as a quota-pressure compatibility path
	// after proving that every desired rule already exists. Never append random
	// ports to it; that was the source of the historical rule leak.
	if !selection.legacy {
		if err := p.ensureFirewallRules(ctx, selection.group, desiredRules); err != nil {
			return p.rollbackNewFirewallGroup(ctx, selection, fmt.Errorf("failed to configure firewall rules: %w", err))
		}
	}
	if err := p.attachFirewallToInstance(ctx, instanceID, selection.group.ID); err != nil {
		return p.rollbackNewFirewallGroup(ctx, selection, fmt.Errorf("failed to attach firewall: %w", err))
	}
	if !selection.legacy {
		if err := p.rememberFirewallGroup(instanceID, ownershipToken, selection.group.ID); err != nil {
			return p.rollbackNewFirewallGroup(ctx, selection, fmt.Errorf("firewall attached but ownership could not be persisted: %w", err))
		}
		// Old process races could have created duplicate groups with the same
		// ownership marker. Now that the selected group is attached, reclaim
		// those duplicates without risking the active group.
		for _, duplicateID := range selection.duplicateIDs {
			if err := p.deleteFirewallGroup(ctx, duplicateID); err != nil {
				return fmt.Errorf("firewall configured, but duplicate managed group %s could not be reclaimed: %w", duplicateID, err)
			}
		}
	}
	return nil
}

func managedFirewallDescription(instanceID, ownershipToken string) string {
	return managedFirewallDescriptionPrefix + strings.TrimSpace(instanceID) + " [" + strings.TrimSpace(ownershipToken) + "]"
}

func isManagedFirewallForInstance(description, instanceID, ownershipToken string) bool {
	if strings.TrimSpace(ownershipToken) == "" {
		return false
	}
	return strings.TrimSpace(description) == managedFirewallDescription(instanceID, ownershipToken)
}

func newFirewallOwnershipToken() (string, error) {
	var token [12]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", fmt.Errorf("failed to generate firewall ownership token: %w", err)
	}
	return hex.EncodeToString(token[:]), nil
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
	if err != nil {
		return "", err
	}
	return token, nil
}

func (p *Provider) rememberFirewallGroup(instanceID, ownershipToken, firewallID string) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok {
			return false, fmt.Errorf("node record disappeared while configuring firewall for %s", instanceID)
		}
		if record.FirewallOwnershipToken != ownershipToken {
			return false, fmt.Errorf("firewall ownership token changed while configuring %s", instanceID)
		}
		if record.FirewallGroupID == firewallID {
			return false, nil
		}
		record.FirewallGroupID = firewallID
		records[instanceID] = record
		return true, nil
	})
}

// isLegacyPrivateDeployFirewall intentionally recognizes only descriptions
// emitted by old PrivateDeploy versions. A user-created group that merely
// contains the word "PrivateDeploy" must never be adopted or deleted.
func isLegacyPrivateDeployFirewall(description string) bool {
	description = strings.TrimSpace(description)
	return description == legacyFirewallDescription || strings.HasPrefix(description, legacyFirewallDescription+" (")
}

func (p *Provider) listFirewallGroups(ctx context.Context) ([]vultrFirewallGroup, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls", nil)
	if err != nil {
		return nil, fmt.Errorf("failed to list firewall groups: %w", err)
	}
	var payload struct {
		FirewallGroups []vultrFirewallGroup `json:"firewall_groups"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, fmt.Errorf("failed to parse firewall groups: %w", err)
	}
	return payload.FirewallGroups, nil
}

func (p *Provider) ensureInstanceFirewallGroup(ctx context.Context, instanceID, ownershipToken string, desiredRules []vultrFirewallRule) (instanceFirewallGroup, error) {
	groups, err := p.listFirewallGroups(ctx)
	if err != nil {
		return instanceFirewallGroup{}, err
	}

	if selection, ok := ownedFirewallSelection(groups, instanceID, ownershipToken); ok {
		return selection, nil
	}

	// When the account is already at Vultr's group cap, an old shared group is
	// safe to reuse only if it already contains the complete rule set. This
	// lets legacy deployments repair without mutating the shared group. New
	// random ports fail clearly instead of leaking rules or touching user data.
	if len(groups) >= vultrFirewallGroupCap {
		for _, group := range groups {
			if !isLegacyPrivateDeployFirewall(group.Description) {
				continue
			}
			matches, matchErr := p.firewallGroupContainsRules(ctx, group.ID, desiredRules)
			if matchErr != nil {
				return instanceFirewallGroup{}, matchErr
			}
			if matches {
				return instanceFirewallGroup{group: group, legacy: true}, nil
			}
		}
		return instanceFirewallGroup{}, fmt.Errorf(
			"Vultr firewall-group cap reached (%d/%d) and no legacy PrivateDeploy group already contains this node's rules; delete an unused firewall group and retry",
			len(groups), vultrFirewallGroupCap,
		)
	}

	createPayload := map[string]any{"description": managedFirewallDescription(instanceID, ownershipToken)}
	res, err := p.apiRequest(ctx, http.MethodPost, "/firewalls", createPayload)
	if err != nil {
		if recovered, ok := p.recoverFirewallCreate(ctx, instanceID, ownershipToken); ok {
			return recovered, nil
		}
		return instanceFirewallGroup{}, fmt.Errorf("failed to create firewall group: %w", err)
	}
	var result struct {
		FirewallGroup vultrFirewallGroup `json:"firewall_group"`
	}
	if err := p.parseResponse(res, &result); err != nil {
		if recovered, ok := p.recoverFirewallCreate(ctx, instanceID, ownershipToken); ok {
			return recovered, nil
		}
		return instanceFirewallGroup{}, fmt.Errorf("failed to create firewall group: %w", err)
	}
	if strings.TrimSpace(result.FirewallGroup.ID) == "" {
		return instanceFirewallGroup{}, fmt.Errorf("Vultr returned an empty firewall group id")
	}
	// Some API responses omit the echoed description; retain the authoritative
	// value used in the request for subsequent ownership checks and tests.
	if result.FirewallGroup.Description == "" {
		result.FirewallGroup.Description = managedFirewallDescription(instanceID, ownershipToken)
	}
	return instanceFirewallGroup{group: result.FirewallGroup, created: true}, nil
}

func ownedFirewallSelection(groups []vultrFirewallGroup, instanceID, ownershipToken string) (instanceFirewallGroup, bool) {
	var owned []vultrFirewallGroup
	for _, group := range groups {
		if isManagedFirewallForInstance(group.Description, instanceID, ownershipToken) {
			owned = append(owned, group)
		}
	}
	if len(owned) > 0 {
		sort.Slice(owned, func(i, j int) bool { return owned[i].ID < owned[j].ID })
		selected := owned[0]
		duplicates := make([]string, 0, len(owned)-1)
		for _, group := range owned[1:] {
			duplicates = append(duplicates, group.ID)
		}
		return instanceFirewallGroup{group: selected, duplicateIDs: duplicates}, true
	}
	return instanceFirewallGroup{}, false
}

func (p *Provider) recoverFirewallCreate(ctx context.Context, instanceID, ownershipToken string) (instanceFirewallGroup, bool) {
	groups, err := p.listFirewallGroups(ctx)
	if err != nil {
		return instanceFirewallGroup{}, false
	}
	selection, ok := ownedFirewallSelection(groups, instanceID, ownershipToken)
	if ok {
		// The POST succeeded remotely even though its response was lost. Treat
		// this as an existing group so later failures don't delete a resource a
		// concurrent repair may already be using.
		selection.created = false
	}
	return selection, ok
}

func (p *Provider) rollbackNewFirewallGroup(_ context.Context, selection instanceFirewallGroup, cause error) error {
	if !selection.created {
		return cause
	}
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if cleanupErr := p.deleteFirewallGroup(cleanupCtx, selection.group.ID); cleanupErr != nil {
		return fmt.Errorf("%v; failed to roll back newly-created firewall group %s: %w", cause, selection.group.ID, cleanupErr)
	}
	return cause
}

func sshFirewallRule() vultrFirewallRule {
	return vultrFirewallRule{
		IPType:     "v4",
		Protocol:   "tcp",
		Subnet:     "0.0.0.0",
		SubnetSize: 0,
		Port:       "22",
		Notes:      "PrivateDeploy SSH Access",
	}
}

func firewallRulesForPorts(ssPort, hysteriaPort, vlessPort, trojanPort, vlessRelayPort int, label string) []vultrFirewallRule {
	rules := []vultrFirewallRule{sshFirewallRule()}
	if ssPort > 0 {
		ssPortStr := strconv.Itoa(ssPort)
		rules = append(rules,
			vultrFirewallRule{IPType: "v4", Protocol: "tcp", Subnet: "0.0.0.0", SubnetSize: 0, Port: ssPortStr, Notes: fmt.Sprintf("%s Shadowsocks TCP", label)},
			vultrFirewallRule{IPType: "v4", Protocol: "udp", Subnet: "0.0.0.0", SubnetSize: 0, Port: ssPortStr, Notes: fmt.Sprintf("%s Shadowsocks UDP", label)},
		)
	}
	if hysteriaPort > 0 {
		rules = append(rules, vultrFirewallRule{IPType: "v4", Protocol: "udp", Subnet: "0.0.0.0", SubnetSize: 0, Port: strconv.Itoa(hysteriaPort), Notes: fmt.Sprintf("%s Hysteria2", label)})
	}
	if vlessPort > 0 {
		rules = append(rules, vultrFirewallRule{IPType: "v4", Protocol: "tcp", Subnet: "0.0.0.0", SubnetSize: 0, Port: strconv.Itoa(vlessPort), Notes: fmt.Sprintf("%s VLESS", label)})
	}
	if trojanPort > 0 {
		rules = append(rules, vultrFirewallRule{IPType: "v4", Protocol: "tcp", Subnet: "0.0.0.0", SubnetSize: 0, Port: strconv.Itoa(trojanPort), Notes: fmt.Sprintf("%s Trojan", label)})
	}
	if vlessRelayPort > 0 {
		rules = append(rules, vultrFirewallRule{IPType: "v4", Protocol: "tcp", Subnet: "0.0.0.0", SubnetSize: 0, Port: strconv.Itoa(vlessRelayPort), Notes: fmt.Sprintf("%s VLESS-Relay (CDN)", label)})
	}
	return rules
}

func firewallRuleKey(rule vultrFirewallRule) string {
	return fmt.Sprintf("%s|%s|%s|%d|%s",
		strings.ToLower(strings.TrimSpace(rule.IPType)),
		strings.ToLower(strings.TrimSpace(rule.Protocol)),
		strings.TrimSpace(rule.Subnet),
		rule.SubnetSize,
		strings.TrimSpace(rule.Port),
	)
}

func (p *Provider) listFirewallRules(ctx context.Context, firewallID string) ([]vultrFirewallRule, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/firewalls/"+firewallID+"/rules", nil)
	if err != nil {
		return nil, fmt.Errorf("failed to list firewall rules: %w", err)
	}
	var payload struct {
		FirewallRules []vultrFirewallRule `json:"firewall_rules"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, fmt.Errorf("failed to parse firewall rules: %w", err)
	}
	return payload.FirewallRules, nil
}

func (p *Provider) firewallGroupContainsRules(ctx context.Context, firewallID string, desired []vultrFirewallRule) (bool, error) {
	existing, err := p.listFirewallRules(ctx, firewallID)
	if err != nil {
		return false, err
	}
	keys := make(map[string]struct{}, len(existing))
	for _, rule := range existing {
		keys[firewallRuleKey(rule)] = struct{}{}
	}
	for _, rule := range desired {
		if _, ok := keys[firewallRuleKey(rule)]; !ok {
			return false, nil
		}
	}
	return true, nil
}

func (p *Provider) ensureFirewallRules(ctx context.Context, group vultrFirewallGroup, desired []vultrFirewallRule) error {
	existing, err := p.listFirewallRules(ctx, group.ID)
	if err != nil {
		return err
	}
	keys := make(map[string]struct{}, len(existing))
	for _, rule := range existing {
		keys[firewallRuleKey(rule)] = struct{}{}
	}
	missing := make([]vultrFirewallRule, 0, len(desired))
	for _, rule := range desired {
		if _, ok := keys[firewallRuleKey(rule)]; !ok {
			missing = append(missing, rule)
		}
	}
	if group.MaxRuleCount > 0 && len(existing)+len(missing) > group.MaxRuleCount {
		return fmt.Errorf(
			"firewall group %s has room for %d rules but this node needs %d additional rules",
			group.ID, group.MaxRuleCount-len(existing), len(missing),
		)
	}

	for _, rule := range missing {
		if err := p.addFirewallRule(ctx, group.ID, rule); err != nil {
			// A previous POST can be accepted even when its response is lost. A
			// read-after-error makes the operation idempotent across that failure.
			present, verifyErr := p.firewallGroupContainsRules(ctx, group.ID, []vultrFirewallRule{rule})
			if verifyErr == nil && present {
				continue
			}
			return err
		}
	}
	return nil
}

func (p *Provider) addFirewallRule(ctx context.Context, firewallID string, rule vultrFirewallRule) error {
	const maxAttempts = 3
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		res, err := p.apiRequest(ctx, http.MethodPost, "/firewalls/"+firewallID+"/rules", rule)
		if err != nil {
			return err
		}
		body, readErr := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if readErr != nil {
			return fmt.Errorf("failed to read firewall rule response: %w", readErr)
		}
		if res.StatusCode < 400 {
			return nil
		}
		if res.StatusCode < http.StatusInternalServerError || attempt == maxAttempts {
			return fmt.Errorf("failed to add firewall rule: %s", decodeVultrError(body))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
	return nil
}

func (p *Provider) attachFirewallToInstance(ctx context.Context, instanceID, firewallID string) error {
	payload := map[string]any{"firewall_group_id": firewallID}
	const maxAttempts = 3
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		res, err := p.apiRequest(ctx, http.MethodPatch, "/instances/"+instanceID, payload)
		if err != nil {
			return fmt.Errorf("failed to attach firewall: %w", err)
		}
		body, readErr := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if readErr != nil {
			return fmt.Errorf("failed to read firewall attach response: %w", readErr)
		}
		if res.StatusCode < 400 {
			return nil
		}
		message := decodeVultrError(body)
		lowerMessage := strings.ToLower(message)
		retryable := res.StatusCode >= http.StatusInternalServerError ||
			(res.StatusCode == http.StatusBadRequest && strings.Contains(lowerMessage, "remote") && strings.Contains(lowerMessage, "response"))
		if !retryable || attempt == maxAttempts {
			return fmt.Errorf("failed to attach firewall to instance: %s", message)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
	return nil
}

func (p *Provider) deleteFirewallGroup(ctx context.Context, firewallID string) error {
	const maxAttempts = 5
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		res, err := p.apiRequest(ctx, http.MethodDelete, "/firewalls/"+firewallID, nil)
		if err != nil {
			return err
		}
		body, readErr := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if readErr != nil {
			return fmt.Errorf("failed to read firewall delete response: %w", readErr)
		}
		if res.StatusCode < 400 || res.StatusCode == http.StatusNotFound {
			return nil
		}

		message := decodeVultrError(body)
		lowerMessage := strings.ToLower(message)
		retryable := res.StatusCode >= http.StatusInternalServerError ||
			res.StatusCode == http.StatusConflict ||
			(res.StatusCode == http.StatusBadRequest &&
				(strings.Contains(lowerMessage, "instance") || strings.Contains(lowerMessage, "attached") || strings.Contains(lowerMessage, "in use")))
		if !retryable || attempt == maxAttempts {
			return fmt.Errorf("failed to delete firewall group: %s", message)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
	return nil
}

// cleanupInstanceFirewallGroups removes only groups whose deterministic
// description proves ownership by instanceID. Legacy shared groups and any
// user-created groups are intentionally left untouched. Duplicate owned
// groups from an older race are all reclaimed.
func (p *Provider) cleanupInstanceFirewallGroups(ctx context.Context, instanceID, ownershipToken string) error {
	if strings.TrimSpace(ownershipToken) == "" {
		// Records created by legacy releases have no cryptographic ownership
		// marker. Leaving their shared group alone is safer than guessing.
		return nil
	}
	firewallLifecycleMu.Lock()
	defer firewallLifecycleMu.Unlock()

	groups, err := p.listFirewallGroups(ctx)
	if err != nil {
		return err
	}
	for _, group := range groups {
		if !isManagedFirewallForInstance(group.Description, instanceID, ownershipToken) {
			continue
		}
		if err := p.deleteFirewallGroup(ctx, group.ID); err != nil {
			return fmt.Errorf("failed to delete managed firewall group %s: %w", group.ID, err)
		}
	}
	return nil
}
