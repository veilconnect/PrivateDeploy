package vultr

import (
	"context"
	"crypto/rand"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
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

func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	if record == nil {
		return false
	}

	changed := false

	if record.HysteriaPort != 0 && record.HysteriaPassword != "" {
		if strings.TrimSpace(record.HysteriaServerName) == "" {
			record.HysteriaServerName = deploy.DefaultHysteriaServerName
			changed = true
		}
		if record.HysteriaInsecure == nil {
			record.HysteriaInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.TrojanPort != 0 && record.TrojanPassword != "" {
		if strings.TrimSpace(record.TrojanServerName) == "" {
			record.TrojanServerName = deploy.DefaultTrojanServerName
			changed = true
		}
		if record.TrojanInsecure == nil {
			record.TrojanInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.VLESSPort != 0 && record.VLESSUUID != "" {
		if strings.TrimSpace(record.VLESSServerName) == "" {
			if strings.TrimSpace(record.TrojanServerName) != "" {
				record.VLESSServerName = record.TrojanServerName
			} else {
				record.VLESSServerName = deploy.DefaultVLESSServerName
			}
			changed = true
		}
	}

	return changed
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

func (p *Provider) waitForTCPPorts(ctx context.Context, ip string, ports []int, timeout time.Duration) error {
	if strings.TrimSpace(ip) == "" {
		return nil
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
		pending := make([]string, 0, len(required))
		allReady := true

		for _, port := range required {
			if isTCPPortReachable(ip, port, serviceReadyDialTimeout) {
				continue
			}
			allReady = false
			pending = append(pending, strconv.Itoa(port))
		}

		if allReady {
			return nil
		}

		select {
		case <-waitCtx.Done():
			return fmt.Errorf("timeout waiting for service ports on %s, pending tcp ports: %s", ip, strings.Join(pending, ","))
		case <-ticker.C:
		}
	}
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
