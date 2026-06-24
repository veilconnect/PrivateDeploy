package digitalocean

import (
	"context"
	"crypto/rand"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

func mergeExtra(base, override map[string]string) map[string]string {
	merged := make(map[string]string, len(base)+len(override))
	for k, v := range base {
		if strings.TrimSpace(k) != "" {
			merged[k] = v
		}
	}
	for k, v := range override {
		if strings.TrimSpace(k) != "" {
			merged[k] = v
		}
	}
	return merged
}

// generateShortID returns a cryptographically random 16-character hex string
// suitable for use as a Reality short ID.
func generateShortID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return fmt.Sprintf("%016x", b)
}

func parseServiceReadyTimeout(extra map[string]string, fallback time.Duration) time.Duration {
	if len(extra) == 0 {
		return fallback
	}
	for _, key := range []string{
		"serviceReadyTimeoutSec",
		"service_ready_timeout_sec",
		"proxyReadyTimeoutSec",
		"proxy_ready_timeout_sec",
	} {
		raw := strings.TrimSpace(extra[key])
		if raw == "" {
			continue
		}
		sec, err := strconv.Atoi(raw)
		if err != nil || sec <= 0 {
			continue
		}
		return time.Duration(sec) * time.Second
	}
	return fallback
}

func (p *Provider) waitForInstanceAndTCPPorts(ctx context.Context, instanceID string, ports []int, timeout time.Duration) (*cloud.Instance, error) {
	requiredPorts := uniquePositivePorts(ports)
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
				pending := pendingTCPPorts(instance.IPv4, requiredPorts, serviceReadyDialTimeout)
				if len(pending) == 0 {
					return instance, nil
				}
				lastErr = fmt.Errorf("pending tcp ports on %s: %s", instance.IPv4, portsToCSV(pending))
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

func uniquePositivePorts(ports []int) []int {
	if len(ports) == 0 {
		return nil
	}
	seen := make(map[int]struct{}, len(ports))
	unique := make([]int, 0, len(ports))
	for _, port := range ports {
		if port <= 0 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		unique = append(unique, port)
	}
	return unique
}

func pendingTCPPorts(ip string, ports []int, timeout time.Duration) []int {
	if strings.TrimSpace(ip) == "" || len(ports) == 0 {
		return ports
	}
	pending := make([]int, 0, len(ports))
	for _, port := range ports {
		if !isTCPPortReachable(ip, port, timeout) {
			pending = append(pending, port)
		}
	}
	return pending
}

func isTCPPortReachable(ip string, port int, timeout time.Duration) bool {
	address := net.JoinHostPort(ip, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func portsToCSV(ports []int) string {
	if len(ports) == 0 {
		return ""
	}
	parts := make([]string, 0, len(ports))
	for _, port := range ports {
		parts = append(parts, strconv.Itoa(port))
	}
	return strings.Join(parts, ",")
}

// ensureManagedTLSDefaults delegates to the shared cloud implementation so the
// managed-protocol TLS defaults stay identical across every provider.
func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	return cloud.EnsureManagedTLSDefaults(record)
}
