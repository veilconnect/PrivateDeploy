// Package provutil holds small, provider-agnostic helpers shared by every
// concrete cloud provider (vultr, digitalocean, ssh, catalog). These functions
// were historically copy-pasted into each provider package; consolidating them
// here keeps a single canonical implementation so a fix in one place can no
// longer drift across providers.
package provutil

import (
	"crypto/rand"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

// MergeExtra returns a new map combining base and override, with override
// winning on key collisions. Blank keys are dropped from both inputs.
func MergeExtra(base, override map[string]string) map[string]string {
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

// GenerateShortID returns a cryptographically random 16-character hex string
// suitable for use as a Reality short ID.
func GenerateShortID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return fmt.Sprintf("%016x", b)
}

// ParseServiceReadyTimeout reads a service-ready timeout (in seconds) from the
// provider extra map, accepting several legacy key spellings. It returns
// fallback when no positive override is present.
func ParseServiceReadyTimeout(extra map[string]string, fallback time.Duration) time.Duration {
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

// UniquePositivePorts returns the input ports with duplicates and non-positive
// values removed, preserving first-seen order.
func UniquePositivePorts(ports []int) []int {
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

// PendingTCPPorts returns the subset of ports that are not currently reachable
// over TCP at ip within timeout. A blank ip or empty port list yields the input
// unchanged.
func PendingTCPPorts(ip string, ports []int, timeout time.Duration) []int {
	if strings.TrimSpace(ip) == "" || len(ports) == 0 {
		return ports
	}
	pending := make([]int, 0, len(ports))
	for _, port := range ports {
		if !IsTCPPortReachable(ip, port, timeout) {
			pending = append(pending, port)
		}
	}
	return pending
}

// IsTCPPortReachable reports whether a TCP connection to ip:port succeeds within
// timeout.
func IsTCPPortReachable(ip string, port int, timeout time.Duration) bool {
	address := net.JoinHostPort(ip, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// PortsToCSV renders ports as a comma-separated string.
func PortsToCSV(ports []int) string {
	if len(ports) == 0 {
		return ""
	}
	parts := make([]string, 0, len(ports))
	for _, port := range ports {
		parts = append(parts, strconv.Itoa(port))
	}
	return strings.Join(parts, ",")
}
