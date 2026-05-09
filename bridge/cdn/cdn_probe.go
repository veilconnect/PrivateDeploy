// Custom-domain TLS readiness probe. Cloudflare's Workers Custom Domains
// API returns success when the binding is created, but the auto-managed
// certificate and edge propagation are asynchronous — first connection
// after attach can hit a not-yet-propagated cert and fail. We surface
// this as a Pending → Active state machine so callers (subscription
// emission, share-link builders) can hold off routing traffic through
// the customHost until CF actually answers TLS on it.
package cdn

import (
	"crypto/tls"
	"net"
	"time"
)

const (
	customHostStatusPending = "pending"
	customHostStatusActive  = "active"
	customHostStatusFailed  = "failed"
)

// probeCustomHostReadiness polls the customHost until TLS handshakes
// succeed or the budget is exhausted. Runs in its own goroutine; persists
// the resulting status under m.mu so the next snapshot/save reflects it.
//
// Budget: 8 attempts at exponential-ish back-off (3,6,12,20,30,40,50,60s)
// = ~3.7 min total. Cloudflare cert propagation typically completes in
// well under that for an active zone.
func (m *Manager) probeCustomHostReadiness(nodeID, host string) {
	delays := []time.Duration{
		3 * time.Second,
		6 * time.Second,
		12 * time.Second,
		20 * time.Second,
		30 * time.Second,
		40 * time.Second,
		50 * time.Second,
		60 * time.Second,
	}
	for _, d := range delays {
		time.Sleep(d)
		if !m.deploymentStillExpectsHost(nodeID, host) {
			return
		}
		if customHostTLSReachable(host, 8*time.Second) {
			m.markCustomHostStatus(nodeID, host, customHostStatusActive)
			return
		}
	}
	m.markCustomHostStatus(nodeID, host, customHostStatusFailed)
}

// customHostTLSReachable does a single TLS handshake against host:443.
// Success means CF edge served a valid cert for the SNI — that's the
// readiness signal we care about. We don't care about the inner Worker
// response yet; the relay path returns 4xx for non-WS requests and that's
// fine.
func customHostTLSReachable(host string, timeout time.Duration) bool {
	dialer := &net.Dialer{Timeout: timeout}
	conn, err := tls.DialWithDialer(dialer, "tcp", host+":443", &tls.Config{
		ServerName: host,
		MinVersion: tls.VersionTLS12,
	})
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// deploymentStillExpectsHost checks the deployment record hasn't been
// deleted/re-bound out from under the probe. Without this, a fast
// delete-and-redeploy cycle could leave a stale probe overwriting a
// fresh deployment's status.
func (m *Manager) deploymentStillExpectsHost(nodeID, host string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	dep, ok := m.deployments[nodeID]
	if !ok || dep == nil {
		return false
	}
	return dep.CustomHost == host
}

// markCustomHostStatus persists a status transition for the deployment
// that still owns this host. Snapshot+lastError are NOT bumped here —
// status changes are passive and the next user-driven action will pick
// them up via GetCdnState.
func (m *Manager) markCustomHostStatus(nodeID, host, status string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	dep, ok := m.deployments[nodeID]
	if !ok || dep == nil || dep.CustomHost != host {
		return
	}
	if dep.CustomHostStatus == status {
		return
	}
	dep.CustomHostStatus = status
	_ = m.saveDeploymentsLocked()
}
