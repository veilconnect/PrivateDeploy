package digitalocean

import (
	"testing"
)

func TestMapDigitalOceanAccountStatus(t *testing.T) {
	cases := []struct {
		name      string
		status    string
		message   string
		wantState string
		canDeploy bool
	}{
		{name: "active", status: "active", wantState: "active", canDeploy: true},
		{name: "warning_with_message", status: "warning", message: "balance low", wantState: "warning", canDeploy: true},
		{name: "warning_blank_message", status: "warning", wantState: "warning", canDeploy: true},
		{name: "locked_with_message", status: "locked", message: "verify identity", wantState: "locked", canDeploy: false},
		{name: "locked_blank_message", status: "locked", wantState: "locked", canDeploy: false},
		{name: "uppercase_active", status: "ACTIVE", wantState: "active", canDeploy: true},
		{name: "padded_locked", status: "  locked  ", wantState: "locked", canDeploy: false},
		{name: "unknown_status", status: "frozen", wantState: "unknown", canDeploy: true},
		{name: "empty_status", status: "", wantState: "unknown", canDeploy: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload := accountResponse{}
			payload.Account.Status = tc.status
			payload.Account.StatusMessage = tc.message

			got := mapDigitalOceanAccountStatus(payload)
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
			if got.Message == "" && tc.wantState != "active" {
				t.Errorf("non-active states should always carry a message; state=%q", got.State)
			}
		})
	}
}
