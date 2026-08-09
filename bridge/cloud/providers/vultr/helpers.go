package vultr

import (
	"context"
	"fmt"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

// ensureManagedTLSDefaults delegates to the shared cloud implementation so the
// managed-protocol TLS defaults stay identical across every provider.
func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	return cloud.EnsureManagedTLSDefaults(record)
}

func (p *Provider) waitForTCPPorts(ctx context.Context, ip string, ports []int, timeout time.Duration) error {
	if strings.TrimSpace(ip) == "" {
		return fmt.Errorf("instance has no public IPv4 address yet")
	}

	required := make([]int, 0, len(ports))
	seen := make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port <= 0 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		required = append(required, port)
	}
	if len(required) == 0 {
		return nil
	}

	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(serviceReadyProbeInterval)
	defer ticker.Stop()

	for {
		pending := provutil.PendingTCPPortsContext(waitCtx, ip, required, serviceReadyDialTimeout)
		if len(pending) == 0 {
			return nil
		}

		select {
		case <-waitCtx.Done():
			return fmt.Errorf("timeout waiting for service ports on %s, pending tcp ports: %s", ip, provutil.PortsToCSV(pending))
		case <-ticker.C:
		}
	}
}
