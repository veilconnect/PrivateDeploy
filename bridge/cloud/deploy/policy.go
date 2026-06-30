package deploy

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/tls"
	"fmt"
	"math/big"
	"net"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	DefaultPortProfile = "random"
	// Hysteria2 inbound uses `masquerade`, which is available starting in sing-box 1.11.0.
	// Primary tracks the version the mobile app ships (kept in lockstep with
	// mobile/lib/features/cloud/vultr_deploy.dart); 1.11.0 is the proven fallback.
	DefaultSingBoxVersion         = "1.12.12"
	DefaultSingBoxFallbackVersion = "1.11.0"
	DefaultHysteriaServerName     = "www.bing.com"
	// VLESS-Reality's server_name is a *live* TLS handshake target ("steal
	// oneself"), unlike Hysteria/Trojan where it is only an SNI label over a
	// self-signed cert. A geo-distributed multi-CDN target (e.g. www.microsoft.com
	// behind Azure Front Door/Akamai) relays an inconsistent handshake and makes
	// sing-box reject clients with "REALITY: processed invalid connection", so
	// VLESS gets its own pool of stable single-origin targets — never microsoft.
	DefaultVLESSServerName  = "dl.google.com"
	DefaultTrojanServerName = "www.microsoft.com"
)

// singBoxKnownSHA256 pins the SHA-256 of the linux-amd64 sing-box release
// tarballs PrivateDeploy ships by default, verified against the upstream GitHub
// release assets. The deploy script integrity-checks the download against these
// (sing-box publishes no per-asset .sha256sum file, so the pin is the trust
// anchor). A version with no entry here — e.g. a user-overridden version we have
// no hash for — degrades to install-without-offline-verification rather than
// blocking the deploy. Update alongside DefaultSingBox*Version on a version bump.
var singBoxKnownSHA256 = map[string]string{
	"1.12.12": "7c103cb2f9a7dc54cb82962043596718ed27989a478d6405f0939a9b775f889f",
	"1.11.0":  "eff0237951bfbd2381be36f114e419f10d3ed57dbf929f680e4cc9f57e319d64",
}

// SingBoxSHA256 returns the pinned linux-amd64 tarball SHA-256 for version, or
// "" when no hash is pinned for it. The leading "v" and surrounding whitespace
// are tolerated.
func SingBoxSHA256(version string) string {
	return singBoxKnownSHA256[strings.TrimPrefix(strings.TrimSpace(version), "v")]
}

var (
	hostnamePattern = regexp.MustCompile(`^[a-zA-Z0-9.-]+$`)
	versionPattern  = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+){1,3}(?:[-+._a-zA-Z0-9]+)?$`)

	hysteriaServerNamePool = []string{
		"www.bing.com",
		"www.cloudflare.com",
		"www.wikipedia.org",
		"www.yahoo.com",
	}
	trojanServerNamePool = []string{
		"www.microsoft.com",
		"www.apple.com",
		"www.cloudflare.com",
	}
	// vlessRealityTargetPool holds vetted Reality handshake targets: stable,
	// single-origin TLS1.3+H2 sites that relay a consistent handshake. Multi-CDN
	// geo-load-balanced sites (microsoft, apple, icloud — Akamai/AFD) are
	// deliberately excluded; they intermittently fail Reality auth. The deploy
	// flow probes these for reachability and picks a live one (see
	// SelectVLESSRealityTarget) so the choice adapts to the client's network.
	vlessRealityTargetPool = []string{
		"dl.google.com",
		"www.cloudflare.com",
		"addons.mozilla.org",
		"www.python.org",
		"swcdn.apple.com",
	}
)

// VLESSRealityTargetPool returns a copy of the vetted Reality handshake targets.
func VLESSRealityTargetPool() []string {
	out := make([]string, len(vlessRealityTargetPool))
	copy(out, vlessRealityTargetPool)
	return out
}

// realityProbe reports whether host currently looks usable as a Reality
// handshake target: a TLS 1.3 handshake on :443 with a valid certificate
// completes within the timeout. It is a package variable so tests can stub it
// without touching the network.
var realityProbe = func(ctx context.Context, host string) bool {
	dialer := tls.Dialer{
		NetDialer: &net.Dialer{Timeout: 4 * time.Second},
		Config:    &tls.Config{ServerName: host, MinVersion: tls.VersionTLS13},
	}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, "443"))
	if err != nil {
		return false
	}
	defer conn.Close()
	tc, ok := conn.(*tls.Conn)
	return ok && tc.ConnectionState().Version == tls.VersionTLS13
}

// SelectVLESSRealityTarget picks the Reality handshake target for a new deploy,
// probing the vetted pool for current reachability so the choice adapts to the
// network. preferred (an explicit override or the tuning default) is tried
// first; if nothing responds, preferred — then the pool default — is the
// last resort. The single returned value MUST be baked into both the deploy
// script and the node record: Reality requires the client's server_name to
// match the server's handshake target exactly, so this has to be decided once,
// at request time, not on the VPS (which can't feed a choice back to the client).
func SelectVLESSRealityTarget(ctx context.Context, preferred string) string {
	preferred = normalizeHostname(preferred, "")
	seen := map[string]bool{}
	var order []string
	add := func(h string) {
		if h != "" && !seen[h] {
			seen[h] = true
			order = append(order, h)
		}
	}
	add(preferred)
	for _, h := range vlessRealityTargetPool {
		add(h)
	}
	for _, h := range order {
		if realityProbe(ctx, h) {
			return h
		}
	}
	if preferred != "" {
		return preferred
	}
	return DefaultVLESSServerName
}

// DeploymentTuning captures optional rollout/security tuning from provider extra fields.
type DeploymentTuning struct {
	PortProfile            string
	SingBoxVersion         string
	SingBoxFallbackVersion string
	HysteriaServerName     string
	HysteriaMasqueradeURL  string
	VLESSServerName        string
	TrojanServerName       string
	HysteriaInsecure       bool
	TrojanInsecure         bool
}

// PortAssignment is the full protocol port layout for a node.
type PortAssignment struct {
	SSPort       int
	HysteriaPort int
	VLESSPort    int
	TrojanPort   int
	// VLESSRelayPort is a non-Reality, non-TLS plain VLESS inbound used as
	// the upstream for a Cloudflare Worker WS↔TCP relay. Always allocated
	// on new deploys so CDN front-ending is available without a re-deploy.
	// Older nodes (provisioned before this field existed) report 0.
	VLESSRelayPort int
}

// ResolveDeploymentTuning normalizes deployment options from provider/instance extra fields.
func ResolveDeploymentTuning(extra map[string]string) DeploymentTuning {
	hysteriaDefault := pickRandomOrDefault(hysteriaServerNamePool, DefaultHysteriaServerName)
	trojanDefault := pickRandomOrDefault(trojanServerNamePool, DefaultTrojanServerName)
	// VLESS-Reality gets its own target from the vetted single-origin pool —
	// never inherited from the Trojan SNI pool (which contains multi-CDN sites
	// that break Reality). The deploy flow may further narrow this by probing.
	vlessDefault := pickRandomOrDefault(vlessRealityTargetPool, DefaultVLESSServerName)

	tuning := DeploymentTuning{
		PortProfile:            DefaultPortProfile,
		SingBoxVersion:         DefaultSingBoxVersion,
		SingBoxFallbackVersion: DefaultSingBoxFallbackVersion,
		HysteriaServerName:     hysteriaDefault,
		VLESSServerName:        vlessDefault,
		TrojanServerName:       trojanDefault,
		HysteriaInsecure:       true,
		TrojanInsecure:         true,
	}

	tuning.PortProfile = NormalizePortProfile(firstExtra(extra,
		"portProfile", "port_profile", "portStrategy", "port_strategy", "portMode", "port_mode",
	))
	tuning.SingBoxVersion = normalizeVersion(firstExtra(extra,
		"singBoxVersion", "sing_box_version", "singboxVersion", "singbox_version",
	), DefaultSingBoxVersion)
	tuning.SingBoxFallbackVersion = normalizeVersion(firstExtra(extra,
		"singBoxFallbackVersion", "sing_box_fallback_version", "singboxFallbackVersion", "singbox_fallback_version",
	), DefaultSingBoxFallbackVersion)
	if tuning.SingBoxFallbackVersion == "" {
		tuning.SingBoxFallbackVersion = tuning.SingBoxVersion
	}

	tuning.HysteriaServerName = normalizeHostname(firstExtra(extra,
		"hysteriaServerName", "hysteria_server_name", "hysteriaSNI", "hysteria_sni",
	), hysteriaDefault)
	tuning.TrojanServerName = normalizeHostname(firstExtra(extra,
		"trojanServerName", "trojan_server_name", "trojanSNI", "trojan_sni",
	), trojanDefault)
	tuning.VLESSServerName = normalizeHostname(firstExtra(extra,
		"vlessServerName", "vless_server_name", "vlessSNI", "vless_sni", "realityServerName", "reality_server_name",
	), vlessDefault)
	if tuning.VLESSServerName == "" {
		tuning.VLESSServerName = DefaultVLESSServerName
	}

	tuning.HysteriaMasqueradeURL = normalizeMasqueradeURL(firstExtra(extra,
		"hysteriaMasqueradeURL", "hysteria_masquerade_url", "masqueradeURL", "masquerade_url",
	), tuning.HysteriaServerName)
	tuning.HysteriaInsecure = parseBoolWithDefault(firstExtra(extra,
		"hysteriaInsecure", "hysteria_insecure", "allowInsecureHysteria",
	), true)
	tuning.TrojanInsecure = parseBoolWithDefault(firstExtra(extra,
		"trojanInsecure", "trojan_insecure", "allowInsecureTrojan",
	), true)

	return tuning
}

// NormalizePortProfile maps unknown values to "random".
func NormalizePortProfile(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "edge443", "edge-443", "camouflage443", "stealth443":
		return "edge443"
	case "edge8443", "edge-8443", "camouflage8443", "stealth8443":
		return "edge8443"
	default:
		return DefaultPortProfile
	}
}

// AllocatePorts picks protocol ports according to a profile.
func AllocatePorts(profile string) PortAssignment {
	switch NormalizePortProfile(profile) {
	case "edge443":
		return PortAssignment{
			SSPort:         24443,
			HysteriaPort:   443,
			VLESSPort:      8443,
			TrojanPort:     443,
			VLESSRelayPort: 24444,
		}
	case "edge8443":
		return PortAssignment{
			SSPort:         28443,
			HysteriaPort:   8443,
			VLESSPort:      9443,
			TrojanPort:     8443,
			VLESSRelayPort: 28444,
		}
	default:
		basePort := randomHighPort()
		return PortAssignment{
			SSPort:         basePort,
			HysteriaPort:   basePort + 1,
			VLESSPort:      basePort + 2,
			TrojanPort:     basePort + 3,
			VLESSRelayPort: basePort + 4,
		}
	}
}

// BoolPtr returns a pointer to value.
func BoolPtr(value bool) *bool {
	v := value
	return &v
}

func firstExtra(extra map[string]string, keys ...string) string {
	if len(extra) == 0 {
		return ""
	}
	for _, key := range keys {
		if value, ok := extra[key]; ok {
			if strings.TrimSpace(value) != "" {
				return value
			}
		}
	}
	return ""
}

func parseBoolWithDefault(raw string, fallback bool) bool {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	case "":
		return fallback
	default:
		return fallback
	}
}

func normalizeHostname(raw, fallback string) string {
	candidate := strings.TrimSpace(strings.ToLower(raw))
	candidate = strings.TrimSuffix(candidate, ".")
	if candidate == "" {
		return fallback
	}
	if !hostnamePattern.MatchString(candidate) {
		return fallback
	}
	if strings.Contains(candidate, "..") || strings.HasPrefix(candidate, ".") || strings.HasSuffix(candidate, ".") {
		return fallback
	}
	for _, part := range strings.Split(candidate, ".") {
		if part == "" || strings.HasPrefix(part, "-") || strings.HasSuffix(part, "-") {
			return fallback
		}
	}
	return candidate
}

func normalizeVersion(raw, fallback string) string {
	candidate := strings.TrimSpace(raw)
	candidate = strings.TrimPrefix(candidate, "v")
	if candidate == "" {
		return fallback
	}
	if !versionPattern.MatchString(candidate) {
		return fallback
	}
	return candidate
}

func normalizeMasqueradeURL(raw, fallbackHost string) string {
	fallback := fmt.Sprintf("https://%s", normalizeHostname(fallbackHost, DefaultHysteriaServerName))
	candidate := strings.TrimSpace(raw)
	if candidate == "" {
		return fallback
	}
	if !strings.Contains(candidate, "://") {
		candidate = "https://" + candidate
	}

	u, err := url.Parse(candidate)
	if err != nil {
		return fallback
	}
	scheme := strings.ToLower(strings.TrimSpace(u.Scheme))
	if scheme != "https" && scheme != "http" {
		return fallback
	}

	host := normalizeHostname(u.Hostname(), "")
	if host == "" {
		return fallback
	}
	hostPort := host
	if port := u.Port(); port != "" {
		hostPort += ":" + port
	}

	normalized := fmt.Sprintf("%s://%s", scheme, hostPort)
	if path := u.EscapedPath(); path != "" {
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
		normalized += path
	}
	if u.RawQuery != "" {
		normalized += "?" + u.RawQuery
	}
	return normalized
}

// secureIntn returns a uniformly random int in [0, n) using crypto/rand. It
// falls back to 0 only if the system CSPRNG fails, which is effectively never.
// Ports and SNI candidates are part of the node's anti-fingerprinting surface,
// so they are drawn from a cryptographic source rather than a predictable PRNG.
func secureIntn(n int) int {
	if n <= 0 {
		return 0
	}
	v, err := cryptorand.Int(cryptorand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(v.Int64())
}

func randomHighPort() int {
	return 20000 + secureIntn(30000)
}

func pickRandomOrDefault(candidates []string, fallback string) string {
	if len(candidates) == 0 {
		return fallback
	}
	picked := normalizeHostname(candidates[secureIntn(len(candidates))], fallback)
	if picked == "" {
		return fallback
	}
	return picked
}
