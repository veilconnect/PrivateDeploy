package vultr

import "testing"

func TestIsVultrTCPReadinessWarning(t *testing.T) {
	for _, warning := range []string{
		"service readiness failed: timeout waiting for ports",
		"instance readiness failed: timeout waiting for active state; service readiness failed: timeout",
	} {
		if !isVultrTCPReadinessWarning(warning) {
			t.Fatalf("expected readiness warning to be refreshable: %q", warning)
		}
	}

	for _, warning := range []string{
		"",
		"Vultr firewall not attached: quota reached",
		"repair failed: managed node credentials are missing",
		"service readiness failed: timeout; Vultr firewall not attached: denied",
	} {
		if isVultrTCPReadinessWarning(warning) {
			t.Fatalf("must not clear non-readiness warning after a TCP probe: %q", warning)
		}
	}
}
