package vultr

import "testing"

func TestFirewallRulesForPortsIncludesSSHOnReusedGroups(t *testing.T) {
	rules := firewallRulesForPorts(31000, 31001, 31002, 31003, "pd-test")
	if len(rules) != 6 {
		t.Fatalf("expected 6 firewall rules, got %d", len(rules))
	}

	first := rules[0]
	if first.Protocol != "tcp" || first.Port != "22" {
		t.Fatalf("expected first rule to allow SSH, got %s/%s", first.Protocol, first.Port)
	}
}

func TestRequiredFirewallRuleCountMatchesGeneratedRules(t *testing.T) {
	got := requiredFirewallRuleCount(32000, 32001, 32002, 32003)
	if got != 6 {
		t.Fatalf("expected 6 required rules, got %d", got)
	}
}

func TestFirewallGroupHasCapacityRejectsFullGroups(t *testing.T) {
	group := vultrFirewallGroup{
		ID:           "fg-full",
		Description:  "PrivateDeploy Auto-Managed Firewall",
		RuleCount:    50,
		MaxRuleCount: 50,
	}
	if firewallGroupHasCapacity(group, 1) {
		t.Fatal("expected full firewall group to reject additional rules")
	}
}
