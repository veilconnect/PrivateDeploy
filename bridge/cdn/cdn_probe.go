// End-to-end relay readiness probe. Cloudflare's Workers Custom Domains
// API returns success when the binding is created, but the auto-managed
// certificate, edge propagation, and Worker→VPS connectivity are all
// asynchronous and can fail independently. We surface this as a
// Pending → Active state machine so callers (subscription emission,
// share-link builders) can hold off routing traffic through the
// customHost until the *full path* (CF edge → Worker → VPS relay
// port) actually answers.
//
// Earlier versions only checked the CF-side TLS handshake. That
// confirmed the cert had propagated but said nothing about whether the
// Worker could reach the VPS — a Worker pointing at a VPS whose UFW
// hadn't been re-opened, or whose vlessRelayPort was wrong, would
// still report "active" and the user's first real connection would
// hang.
package cdn

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	customHostStatusPending = "pending"
	customHostStatusActive  = "active"
	customHostStatusFailed  = "failed"
)

// probeCustomHostReadiness polls the customHost until the WS upgrade
// succeeds end-to-end (CF cert + Worker dispatch + Worker→VPS TCP) or
// the budget is exhausted. Runs in its own goroutine; persists the
// resulting status under m.mu so the next snapshot/save reflects it.
//
// Two-stage probe: TLS first (fast, no path-secret needed), then a WS
// upgrade with the deployment's path-secret. Splitting them lets us
// stay in "pending" while only the cert is propagating (cheap) and
// only spend the upgrade round-trip once TLS succeeds.
//
// Budget: 8 attempts at exponential-ish back-off (3,6,12,20,30,40,50,60s)
// = ~3.7 min total. Cloudflare cert propagation typically completes in
// well under that for an active zone; Worker→VPS becomes reachable
// the instant UFW + vlessRelayPort are correct.
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
		// Cheap TLS handshake first — if the cert isn't propagated yet
		// there's no point spending a WS upgrade round-trip. Lets us
		// distinguish "cert pending" from "Worker→VPS broken" later
		// if we ever surface diagnostic detail.
		if !customHostTLSReachable(host, 8*time.Second) {
			continue
		}
		secret := m.deploymentPathSecret(nodeID, host)
		if secret == "" {
			// Legacy deployment with no path-secret on record. Best
			// we can do is the TLS check above; mark active so it
			// doesn't sit in "pending" forever.
			m.markCustomHostStatus(nodeID, host, customHostStatusActive)
			return
		}
		if customHostRelayReachable(host, secret, 12*time.Second) {
			m.markCustomHostStatus(nodeID, host, customHostStatusActive)
			return
		}
	}
	m.markCustomHostStatus(nodeID, host, customHostStatusFailed)
}

// customHostTLSReachable does a single TLS handshake against host:443.
// Success means CF edge served a valid cert for the SNI — necessary
// but not sufficient for the relay to work end-to-end.
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

// customHostRelayReachable attempts the full WS upgrade through the
// Worker, exercising the entire CF-edge → Worker → VPS relay path.
// Success means the Worker accepted the path-secret AND established a
// TCP connection to the VPS upstream. We close immediately — we don't
// care about VLESS payload exchange, only that 101 came back.
//
// A 502/504 from the Worker means the Worker→VPS TCP failed (UFW,
// wrong port, VPS down). 404 means the path-secret didn't match
// (placeholder didn't render, or deployment record drift).
func customHostRelayReachable(host, pathSecret string, timeout time.Duration) bool {
	if host == "" || pathSecret == "" {
		return false
	}
	u := &url.URL{
		Scheme:   "wss",
		Host:     host,
		Path:     "/",
		RawQuery: "ed=2560&k=" + url.QueryEscape(pathSecret),
	}
	dialer := &websocket.Dialer{
		HandshakeTimeout: timeout,
		// Use the system root CAs; CF's managed cert chains to a
		// public root so this just works.
		TLSClientConfig: &tls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, resp, err := dialer.DialContext(ctx, u.String(), http.Header{
		"User-Agent": []string{"PrivateDeploy-CDN-Probe/1"},
	})
	if resp != nil {
		// Body is small; drain so the connection can be reused / closed
		// cleanly. Errors here are harmless.
		_ = resp.Body.Close()
	}
	if err != nil {
		// gorilla/websocket returns ErrBadHandshake when the server
		// answered HTTP but didn't switch protocols — that's the case
		// for 502/504 (Worker→VPS broken) or 404 (secret mismatch).
		// Both indicate the relay isn't ready, so report failure.
		if errors.Is(err, websocket.ErrBadHandshake) && resp != nil {
			// Could log resp.StatusCode here for diagnostic; left
			// quiet to avoid log spam during normal pending phase.
			return false
		}
		return false
	}
	_ = conn.Close()
	return true
}

// deploymentPathSecret returns the per-deployment path-secret if and
// only if the deployment still owns this host. Reading under the lock
// matches the deploymentStillExpectsHost pattern.
func (m *Manager) deploymentPathSecret(nodeID, host string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	dep, ok := m.deployments[nodeID]
	if !ok || dep == nil || dep.CustomHost != host {
		return ""
	}
	return strings.TrimSpace(dep.PathSecret)
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
