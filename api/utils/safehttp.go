package utils

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"
)

// ErrBlockedOutboundURL is returned when an outbound request targets a
// non-public address or uses an unsupported scheme. It mirrors the desktop
// bridge's SSRF guard so the headless API enforces the same boundary on
// user-supplied URLs (e.g. subscription source URLs).
var ErrBlockedOutboundURL = errors.New("blocked outbound request to a non-public or unsupported address")

// isBlockedDialIP reports whether an IP must not be reachable from a
// user-supplied URL fetch: loopback, RFC1918 private ranges, link-local
// (incl. the 169.254.169.254 cloud metadata endpoint), CGNAT, NAT64,
// unique-local IPv6, multicast and unspecified addresses.
func isBlockedDialIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() ||
		ip.IsUnspecified() {
		return true
	}

	// IsPrivate covers RFC1918 + fc00::/7, but not these additional
	// not-publicly-routable ranges that can still reach internal infra.
	if ip4 := ip.To4(); ip4 != nil {
		// CGNAT 100.64.0.0/10 (RFC6598).
		if ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
			return true
		}
		// Limited broadcast.
		if ip4[0] == 255 && ip4[1] == 255 && ip4[2] == 255 && ip4[3] == 255 {
			return true
		}
	} else if len(ip) == net.IPv6len && ip[0] == 0x00 && ip[1] == 0x64 && ip[2] == 0xff && ip[3] == 0x9b {
		// NAT64 well-known prefix 64:ff9b::/96 can embed private IPv4 targets.
		return true
	}
	return false
}

// ssrfSafeControl runs against the actual resolved IP immediately before
// connect, closing the DNS-rebinding TOCTOU window a URL-string-only check
// would leave open. Because the transport reuses this dialer, it also fires
// for every redirect hop.
func ssrfSafeControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		host = address
	}
	if isBlockedDialIP(net.ParseIP(strings.Trim(host, "[]"))) {
		return fmt.Errorf("%w: %s", ErrBlockedOutboundURL, address)
	}
	return nil
}

// ValidateOutboundURL is the cheap up-front guard: it enforces http(s) and
// rejects a host literal that is obviously loopback/internal. The
// authoritative check is the dial-time Control hook in SSRFSafeClient, which
// sees the resolved IP and is therefore safe against DNS rebinding.
func ValidateOutboundURL(raw string) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ErrBlockedOutboundURL
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
	default:
		return ErrBlockedOutboundURL
	}
	host := parsed.Hostname()
	if host == "" || strings.EqualFold(host, "localhost") {
		return ErrBlockedOutboundURL
	}
	if ip := net.ParseIP(host); ip != nil && isBlockedDialIP(ip) {
		return ErrBlockedOutboundURL
	}
	return nil
}

// SSRFSafeClient returns an *http.Client that refuses to dial any internal
// address — checked at the resolved IP, on every hop including redirects.
func SSRFSafeClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: 10 * time.Second, Control: ssrfSafeControl}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:           dialer.DialContext,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          10,
			IdleConnTimeout:       30 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		},
	}
}
