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
//
// DNS resolution goes through DoH (see resolveViaDoH) instead of the OS
// resolver. The probe fires within seconds of the Workers Custom Domain
// binding, before CF's auto-DNS has propagated. The OS resolver returns
// NXDOMAIN, then per RFC 2308 caches it negatively for the zone's
// SOA-MIN — typically far longer than the 3.7-min probe budget, so one
// early NXDOMAIN poisons every subsequent iteration. AOSP's netd and
// glibc's nscd / systemd-resolved both honor SOA-MIN, so the bug is
// cross-platform; mobile (cellular) hits it hardest but desktop is not
// immune. DoH bypass dodges both caches by going straight to
// authoritative-by-proxy resolvers each iteration.
package cdn

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

// dohEndpoints, tried in order until one returns A records. Hardcoded
// to IP literals so we never consult the OS resolver for the DoH
// provider itself (which would re-introduce the negative-cache hazard
// the whole DoH path exists to dodge). AliDNS is listed first because
// the app's primary audience is CN cellular, where CF/Google are
// reachable but markedly slower (200ms+ RTT) and sometimes middleboxed.
// CF/Google trail as fallbacks for non-CN networks.
var dohEndpoints = []string{
	"https://223.5.5.5/resolve", // AliDNS (CN-friendly)
	"https://223.6.6.6/resolve", // AliDNS secondary
	"https://1.1.1.1/dns-query", // Cloudflare
	"https://1.0.0.1/dns-query", // Cloudflare secondary
	"https://8.8.8.8/resolve",   // Google
}

// dohClient is module-private and goroutine-safe. The transport pins
// timeouts well below the per-iteration probe budget so a slow DoH
// endpoint can't burn the whole iteration.
var dohClient = &http.Client{
	Timeout: 12 * time.Second,
	Transport: &http.Transport{
		// Disable connection pooling between probes — the IP-literal
		// endpoints are short-lived, and pooling adds no benefit while
		// risking stale connections across long delays.
		DisableKeepAlives: true,
	},
}

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
// Budget: ~24 min of exponential-ish back-off. Cloudflare managed-cert
// issuance + edge propagation for a brand-new custom hostname, and a
// freshly-booted VPS opening UFW + vlessRelayPort, both routinely exceed
// the first few minutes — an earlier ~3.7-min budget marked correct
// deploys terminally "failed". load() re-runs this on every launch so a
// node self-heals once CF/VPS settle.
func (m *Manager) probeCustomHostReadiness(nodeID, host string) {
	// Total budget ~24 min. The long tail covers worst-case Cloudflare
	// managed-cert issuance + edge propagation for a brand-new custom
	// hostname, and a freshly-booted VPS opening its relay port. A
	// too-short budget here is what made correct deploys get stranded as
	// permanently-"failed"; load() now re-runs this on every launch.
	delays := []time.Duration{
		3 * time.Second,
		6 * time.Second,
		12 * time.Second,
		20 * time.Second,
		30 * time.Second,
		40 * time.Second,
		50 * time.Second,
		60 * time.Second,
		90 * time.Second,
		120 * time.Second,
		180 * time.Second,
		240 * time.Second,
		300 * time.Second,
		300 * time.Second,
	}
	for _, d := range delays {
		time.Sleep(d)
		if !m.deploymentStillExpectsHost(nodeID, host) {
			return
		}
		// Resolve once per iteration via DoH; both checks reuse the IPs.
		// Empty list means CF hasn't published the record yet — short
		// circuit and wait for the next backoff.
		ips := resolveViaDoH(host)
		if len(ips) == 0 {
			continue
		}
		// Cheap TLS handshake first — if the cert isn't propagated yet
		// there's no point spending a WS upgrade round-trip. Lets us
		// distinguish "cert pending" from "Worker→VPS broken" later
		// if we ever surface diagnostic detail.
		if !customHostTLSReachable(ips, host, 8*time.Second) {
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
		if customHostRelayReachable(ips, host, secret, 12*time.Second) {
			m.markCustomHostStatus(nodeID, host, customHostStatusActive)
			return
		}
	}
	m.markCustomHostStatus(nodeID, host, customHostStatusFailed)
}

// customHostTLSReachable does a TLS handshake to the first DoH-resolved
// IP using customHost as the SNI/Host. Success means CF edge served a
// valid cert for the SNI — necessary but not sufficient for the relay
// to work end-to-end. Connecting to the IP directly avoids the OS
// resolver (see package doc on RFC 2308 negative-cache hazard).
func customHostTLSReachable(ips []net.IP, host string, timeout time.Duration) bool {
	if len(ips) == 0 {
		return false
	}
	dialer := &net.Dialer{Timeout: timeout}
	addr := net.JoinHostPort(ips[0].String(), "443")
	conn, err := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{
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
// gorilla/websocket.Dialer.NetDialContext routes the connect to the
// DoH-resolved IP; the URL stays as wss://customHost/... so the HTTP
// Host header CF sees is still customHost, which is what custom-domain
// routing keys on.
//
// A 502/504 from the Worker means the Worker→VPS TCP failed (UFW,
// wrong port, VPS down). 404 means the path-secret didn't match
// (placeholder didn't render, or deployment record drift).
func customHostRelayReachable(ips []net.IP, host, pathSecret string, timeout time.Duration) bool {
	if len(ips) == 0 || host == "" || pathSecret == "" {
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
		TLSClientConfig: &tls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		},
		// Override the connect step so we open TCP to the DoH-resolved
		// IP instead of letting the OS resolver chew on customHost.
		// Strip the (potentially synthetic) port from addr and use 443
		// regardless — wss → 443 is unambiguous for our deploys.
		NetDialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			d := &net.Dialer{Timeout: timeout}
			return d.DialContext(ctx, network, net.JoinHostPort(ips[0].String(), "443"))
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

// resolveViaDoH walks the dohEndpoints list and returns the first
// non-empty A-record list. Each endpoint gets its own short timeout
// (via dohClient) so a slow/unreachable endpoint can't dominate the
// per-iteration budget.
//
// Endpoints are queried in fixed order, not in parallel — the assumption
// is the first one (AliDNS for CN; trivially routed for non-CN) is
// almost always reachable, and parallel queries would only matter when
// the primary fails, which is rare enough that serial fallback is fine.
func resolveViaDoH(host string) []net.IP {
	if host == "" {
		return nil
	}
	var ips []net.IP
	for _, ep := range dohEndpoints {
		ips = dohQuery(ep, host)
		if len(ips) > 0 {
			return ips
		}
	}
	return nil
}

// dohQuery sends a single DoH JSON request and parses the answer. The
// JSON shape is the Google/Cloudflare convention also adopted by
// AliDNS at the /resolve path. Wire-format DoH (POST application/dns-message)
// would also work but pulls in miekg/dns; the JSON path is dependency-free.
func dohQuery(endpoint, host string) []net.IP {
	req, err := http.NewRequest(http.MethodGet,
		fmt.Sprintf("%s?name=%s&type=A", endpoint, url.QueryEscape(host)), nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Accept", "application/dns-json")
	resp, err := dohClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024))
	if err != nil {
		return nil
	}
	var parsed struct {
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil
	}
	out := make([]net.IP, 0, len(parsed.Answer))
	for _, a := range parsed.Answer {
		// type 1 = A, type 28 = AAAA. We ask for A above so type-1 is
		// the common path; defensively accept 28 in case the resolver
		// returns mixed answers.
		if a.Type != 1 && a.Type != 28 {
			continue
		}
		ip := net.ParseIP(strings.TrimSpace(a.Data))
		if ip != nil {
			out = append(out, ip)
		}
	}
	return out
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
