package digitalocean

import (
	"context"
	"fmt"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

func (p *Provider) waitForInstanceAndTCPPorts(ctx context.Context, instanceID string, ports []int, timeout time.Duration) (*cloud.Instance, error) {
	requiredPorts := provutil.UniquePositivePorts(ports)
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(serviceReadyProbeInterval)
	defer ticker.Stop()

	var lastErr error

	for {
		instance, err := p.GetInstance(waitCtx, instanceID)
		if err != nil {
			lastErr = err
		} else if instance != nil {
			status := strings.ToLower(strings.TrimSpace(instance.Status))
			if (status == "active" || status == "running") && strings.TrimSpace(instance.IPv4) != "" {
				pending := provutil.PendingTCPPorts(instance.IPv4, requiredPorts, serviceReadyDialTimeout)
				if len(pending) == 0 {
					return instance, nil
				}
				lastErr = fmt.Errorf("pending tcp ports on %s: %s", instance.IPv4, provutil.PortsToCSV(pending))
			} else {
				lastErr = fmt.Errorf("instance not ready yet: status=%s ipv4=%s", status, strings.TrimSpace(instance.IPv4))
			}
		}

		select {
		case <-waitCtx.Done():
			if lastErr != nil {
				return nil, fmt.Errorf("timeout waiting for digitalocean instance %s readiness: %w", instanceID, lastErr)
			}
			return nil, fmt.Errorf("timeout waiting for digitalocean instance %s readiness", instanceID)
		case <-ticker.C:
		}
	}
}

// ensureManagedTLSDefaults delegates to the shared cloud implementation so the
// managed-protocol TLS defaults stay identical across every provider.
func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	return cloud.EnsureManagedTLSDefaults(record)
}
