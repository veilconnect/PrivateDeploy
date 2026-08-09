package vultr

import (
	"testing"
)

func TestClassifyVultrFirewallQuota(t *testing.T) {
	cases := []struct {
		name      string
		total     int
		wantState string
		canDeploy bool
	}{
		{name: "empty_account", total: 0, wantState: "active", canDeploy: true},
		{name: "well_under_threshold", total: 12, wantState: "active", canDeploy: true},
		{name: "boundary_below_warn", total: 44, wantState: "active", canDeploy: true},
		{name: "warn_threshold_hit", total: 45, wantState: "warning", canDeploy: true},
		{name: "warn_zone", total: 47, wantState: "warning", canDeploy: true},
		{name: "cap_reached", total: 50, wantState: "locked", canDeploy: false},
		{name: "cap_exceeded", total: 52, wantState: "locked", canDeploy: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyVultrFirewallQuota(tc.total)
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
