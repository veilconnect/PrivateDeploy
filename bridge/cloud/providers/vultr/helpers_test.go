package vultr

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestWaitForTCPPortsRejectsMissingAddress(t *testing.T) {
	err := (&Provider{}).waitForTCPPorts(context.Background(), "", []int{443}, time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "no public IPv4") {
		t.Fatalf("waitForTCPPorts() error = %v, want missing-address error", err)
	}
}
