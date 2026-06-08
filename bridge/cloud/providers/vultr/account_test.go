package vultr

import (
	"testing"
)

func TestClassifyVultrFirewallQuota(t *testing.T) {
	cases := []struct {
		name      string
		total     int
		reusable  int
		wantState string
		canDeploy bool
	}{
		{name: "empty_account", total: 0, reusable: 0, wantState: "active", canDeploy: true},
		{name: "well_under_threshold", total: 12, reusable: 1, wantState: "active", canDeploy: true},
		{name: "boundary_below_warn", total: 44, reusable: 1, wantState: "active", canDeploy: true},
		{name: "warn_threshold_hit", total: 45, reusable: 1, wantState: "warning", canDeploy: true},
		{name: "warn_zone_no_reusable", total: 47, reusable: 0, wantState: "warning", canDeploy: true},
		{name: "cap_reached_with_reuse", total: 50, reusable: 2, wantState: "locked", canDeploy: true},
		{name: "cap_reached_no_reuse", total: 50, reusable: 0, wantState: "locked", canDeploy: false},
		{name: "cap_exceeded", total: 52, reusable: 1, wantState: "locked", canDeploy: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyVultrFirewallQuota(tc.total, tc.reusable)
			if got == nil {
				t.Fatal("expected non-nil status")
			}
			if got.State != tc.wantState {
				t.Errorf("state = %q, want %q", got.State, tc.wantState)
			}
			if got.CanDeploy != tc.canDeploy {
				t.Errorf("canDeploy = %v, want %v", got.CanDeploy, tc.canDeploy)
			}
			if got.CheckedAt.IsZero() {
				t.Error("CheckedAt should be set")
			}
			if tc.wantState != "active" && got.Message == "" {
				t.Errorf("non-active states must carry a message; state=%q", got.State)
			}
		})
	}
}
