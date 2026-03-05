package deploy

import (
	"fmt"
	mathrand "math/rand"
	"net/url"
	"regexp"
	"strings"
)

const (
	DefaultPortProfile            = "random"
	DefaultSingBoxVersion         = "1.10.0"
	DefaultSingBoxFallbackVersion = "1.10.0"
	DefaultHysteriaServerName     = "www.bing.com"
	DefaultVLESSServerName        = "www.microsoft.com"
	DefaultTrojanServerName       = "www.microsoft.com"
)

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
		"www.amazon.com",
		"www.github.com",
		"www.cloudflare.com",
	}
)

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
}

// ResolveDeploymentTuning normalizes deployment options from provider/instance extra fields.
func ResolveDeploymentTuning(extra map[string]string) DeploymentTuning {
	hysteriaDefault := pickRandomOrDefault(hysteriaServerNamePool, DefaultHysteriaServerName)
	trojanDefault := pickRandomOrDefault(trojanServerNamePool, DefaultTrojanServerName)

	tuning := DeploymentTuning{
		PortProfile:            DefaultPortProfile,
		SingBoxVersion:         DefaultSingBoxVersion,
		SingBoxFallbackVersion: DefaultSingBoxFallbackVersion,
		HysteriaServerName:     hysteriaDefault,
		VLESSServerName:        trojanDefault,
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
	), tuning.TrojanServerName)
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
			SSPort:       24443,
			HysteriaPort: 443,
			VLESSPort:    8443,
			TrojanPort:   443,
		}
	case "edge8443":
		return PortAssignment{
			SSPort:       28443,
			HysteriaPort: 8443,
			VLESSPort:    9443,
			TrojanPort:   8443,
		}
	default:
		basePort := randomHighPort()
		return PortAssignment{
			SSPort:       basePort,
			HysteriaPort: basePort + 1,
			VLESSPort:    basePort + 2,
			TrojanPort:   basePort + 3,
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

func randomHighPort() int {
	return 20000 + mathrand.Intn(30000)
}

func pickRandomOrDefault(candidates []string, fallback string) string {
	if len(candidates) == 0 {
		return fallback
	}
	picked := normalizeHostname(candidates[mathrand.Intn(len(candidates))], fallback)
	if picked == "" {
		return fallback
	}
	return picked
}
