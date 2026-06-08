package catalog

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

func (p *Provider) baseURL() string {
	switch p.name {
	case "hetzner":
		return hetznerAPIBaseURL
	case "linode":
		return linodeAPIBaseURL
	case "scaleway":
		return scalewayAPIBaseURL
	case "upcloud":
		return upcloudAPIBaseURL
	case "contabo":
		return contaboAPIBaseURL
	default:
		return ""
	}
}

func (p *Provider) cloudID(rawID string) string {
	return "cloud-" + p.name + "-" + rawID
}

func (p *Provider) stripCloudPrefix(instanceID string) string {
	prefix := "cloud-" + p.name + "-"
	if strings.HasPrefix(instanceID, prefix) {
		return strings.TrimPrefix(instanceID, prefix)
	}
	return strings.TrimSpace(instanceID)
}

func (p *Provider) remotePathForID(remoteID string) string {
	switch p.name {
	case "hetzner":
		return "/servers/" + url.PathEscape(remoteID)
	case "linode":
		return "/linode/instances/" + url.PathEscape(remoteID)
	case "scaleway":
		zone, serverID, ok := parseScopedRemoteID(remoteID)
		if !ok {
			return ""
		}
		return fmt.Sprintf("/instance/v1/zones/%s/servers/%s", url.PathEscape(zone), url.PathEscape(serverID))
	case "upcloud":
		return "/server/" + url.PathEscape(remoteID)
	case "contabo":
		return "/v1/compute/instances/" + url.PathEscape(remoteID)
	default:
		return ""
	}
}

func (p *Provider) regionIDs() []string {
	ids := make([]string, 0, len(p.regions))
	for _, r := range p.regions {
		if id := strings.TrimSpace(r.ID); id != "" {
			ids = append(ids, id)
		}
	}
	if len(ids) > 0 {
		return ids
	}
	return []string{}
}

func scopedRemoteID(scope, id string) string {
	s := strings.TrimSpace(scope)
	i := strings.TrimSpace(id)
	if s == "" {
		return i
	}
	return s + "|" + i
}

func parseScopedRemoteID(raw string) (scope, id string, ok bool) {
	parts := strings.SplitN(strings.TrimSpace(raw), "|", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	scope = strings.TrimSpace(parts[0])
	id = strings.TrimSpace(parts[1])
	if scope == "" || id == "" {
		return "", "", false
	}
	return scope, id, true
}

func safeHostname(label, fallback string) string {
	value := strings.ToLower(strings.TrimSpace(label))
	if value == "" {
		value = fallback
	}
	var b strings.Builder
	prevDash := false
	for _, r := range value {
		isAlphaNum := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if isAlphaNum {
			b.WriteRune(r)
			prevDash = false
			continue
		}
		if !prevDash {
			b.WriteRune('-')
			prevDash = true
		}
	}
	host := strings.Trim(b.String(), "-")
	if host == "" {
		host = fallback
	}
	if len(host) > 63 {
		host = strings.Trim(host[:63], "-")
	}
	if host == "" {
		host = "pd-node"
	}
	return host
}

func anyToString(v any) string {
	if v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case json.Number:
		return strings.TrimSpace(t.String())
	case float64:
		if math.Mod(t, 1) == 0 {
			return strconv.FormatInt(int64(t), 10)
		}
		return strings.TrimSpace(strconv.FormatFloat(t, 'f', -1, 64))
	case float32:
		f := float64(t)
		if math.Mod(f, 1) == 0 {
			return strconv.FormatInt(int64(f), 10)
		}
		return strings.TrimSpace(strconv.FormatFloat(f, 'f', -1, 64))
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case uint64:
		return strconv.FormatUint(t, 10)
	case map[string]any:
		if name := anyToString(t["name"]); name != "" {
			return name
		}
		if status := anyToString(t["status"]); status != "" {
			return status
		}
		return ""
	default:
		return strings.TrimSpace(fmt.Sprint(v))
	}
}

func normalizeStatus(v any) string {
	return firstNonEmpty(strings.ToLower(anyToString(v)), "unknown")
}

func asMap(v any) map[string]any {
	if v == nil {
		return nil
	}
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return nil
}

func contaboIPConfig(v any) (string, string) {
	cfg := asMap(v)
	if cfg == nil {
		return "", ""
	}
	v4 := asMap(cfg["v4"])
	v6 := asMap(cfg["v6"])
	return strings.TrimSpace(anyToString(v4["ip"])), strings.TrimSpace(anyToString(v6["ip"]))
}

func upcloudIPs(list []struct {
	Address string `json:"address"`
	Family  string `json:"family"`
	Access  string `json:"access"`
}) (string, string) {
	ipv4 := ""
	ipv6 := ""
	for _, item := range list {
		addr := strings.TrimSpace(item.Address)
		if addr == "" {
			continue
		}
		family := strings.ToLower(strings.TrimSpace(item.Family))
		access := strings.ToLower(strings.TrimSpace(item.Access))
		if family == "ipv4" && (access == "" || access == "public") && ipv4 == "" {
			ipv4 = addr
			continue
		}
		if family == "ipv6" && (access == "" || access == "public") && ipv6 == "" {
			ipv6 = addr
		}
	}
	return ipv4, ipv6
}

func parseAPIKeyObject(apiKey string) map[string]string {
	raw := strings.TrimSpace(apiKey)
	if raw == "" || !(strings.HasPrefix(raw, "{") && strings.HasSuffix(raw, "}")) {
		return nil
	}
	var generic map[string]any
	if err := json.Unmarshal([]byte(raw), &generic); err != nil {
		return nil
	}
	out := make(map[string]string, len(generic))
	for k, v := range generic {
		key := strings.TrimSpace(strings.ToLower(k))
		if key == "" {
			continue
		}
		out[key] = strings.TrimSpace(anyToString(v))
	}
	return out
}

func lookupMapValue(values map[string]string, keys ...string) string {
	if values == nil {
		return ""
	}
	for _, key := range keys {
		if v, ok := values[strings.ToLower(strings.TrimSpace(key))]; ok {
			if s := strings.TrimSpace(v); s != "" {
				return s
			}
		}
	}
	return ""
}

func upcloudCredentials(cfg *cloud.ProviderConfig) (string, string, error) {
	if cfg == nil {
		return "", "", cloud.ErrInvalidConfig
	}
	extra := cfg.Extra
	jsonObj := parseAPIKeyObject(cfg.APIKey)

	username := firstNonEmpty(
		strings.TrimSpace(extra["username"]),
		strings.TrimSpace(extra["user"]),
		strings.TrimSpace(extra["apiUsername"]),
		lookupMapValue(jsonObj, "username", "user", "apiusername"),
	)
	password := firstNonEmpty(
		strings.TrimSpace(extra["password"]),
		strings.TrimSpace(extra["apiPassword"]),
		lookupMapValue(jsonObj, "password", "apipassword"),
	)

	if username == "" || password == "" {
		parts := strings.SplitN(strings.TrimSpace(cfg.APIKey), ":", 2)
		if len(parts) == 2 {
			if username == "" {
				username = strings.TrimSpace(parts[0])
			}
			if password == "" {
				password = strings.TrimSpace(parts[1])
			}
		}
	}

	if username == "" || password == "" {
		return "", "", fmt.Errorf("upcloud requires username and password in api key or extra")
	}
	return username, password, nil
}

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

func firstPublicIPv4(list []string) string {
	for _, ip := range list {
		trimmed := strings.TrimSpace(ip)
		if trimmed == "" || strings.Contains(trimmed, ":") {
			continue
		}
		return trimmed
	}
	return ""
}

func uniquePositivePorts(ports []int) []int {
	seen := make(map[int]struct{}, len(ports))
	out := make([]int, 0, len(ports))
	for _, port := range ports {
		if port <= 0 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		out = append(out, port)
	}
	return out
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
	addr := net.JoinHostPort(ip, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func portsToCSV(ports []int) string {
	parts := make([]string, 0, len(ports))
	for _, port := range ports {
		parts = append(parts, strconv.Itoa(port))
	}
	return strings.Join(parts, ",")
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

func parseRFC3339(raw string) time.Time {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(raw))
	if err != nil {
		return time.Time{}
	}
	return t
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if s := strings.TrimSpace(v); s != "" {
			return s
		}
	}
	return ""
}

func firstPriceNet(prices []struct {
	PriceHourly struct {
		Net string `json:"net"`
	} `json:"price_hourly"`
}) string {
	if len(prices) == 0 {
		return ""
	}
	return prices[0].PriceHourly.Net
}

func parseFloat(raw string) float64 {
	f, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil {
		return 0
	}
	return f
}

func scalewayZoneLocation(zone string) (string, string) {
	switch strings.ToLower(strings.TrimSpace(zone)) {
	case "fr-par-1", "fr-par-2", "fr-par-3":
		return "Paris", "France"
	case "nl-ams-1", "nl-ams-2":
		return "Amsterdam", "Netherlands"
	case "pl-waw-1", "pl-waw-2":
		return "Warsaw", "Poland"
	default:
		return "", ""
	}
}

func countryFromRegionID(regionID string) string {
	id := strings.ToLower(strings.TrimSpace(regionID))
	switch {
	case strings.HasPrefix(id, "us-"):
		return "United States"
	case strings.HasPrefix(id, "de-"), strings.HasPrefix(id, "eu-"):
		return "Germany"
	case strings.HasPrefix(id, "uk-"), strings.HasPrefix(id, "gb-"):
		return "United Kingdom"
	case strings.HasPrefix(id, "fi-"):
		return "Finland"
	case strings.HasPrefix(id, "sg-"), strings.HasPrefix(id, "sin"):
		return "Singapore"
	case strings.HasPrefix(id, "jp-"):
		return "Japan"
	case strings.HasPrefix(id, "au-"):
		return "Australia"
	case strings.HasPrefix(id, "in-"):
		return "India"
	case strings.HasPrefix(id, "pl-"):
		return "Poland"
	case strings.HasPrefix(id, "nl-"):
		return "Netherlands"
	case strings.HasPrefix(id, "fr-"):
		return "France"
	default:
		return ""
	}
}

func countryFromContaboRegion(regionID string) string {
	switch strings.ToUpper(strings.TrimSpace(regionID)) {
	case "EU":
		return "Germany"
	case "US-CENTRAL", "US-EAST", "US-WEST":
		return "United States"
	case "SIN":
		return "Singapore"
	case "UK":
		return "United Kingdom"
	case "AUS":
		return "Australia"
	case "JPN":
		return "Japan"
	case "IND":
		return "India"
	default:
		return ""
	}
}

func normalizeContaboRegion(region string) string {
	r := strings.TrimSpace(region)
	if r == "" {
		return ""
	}
	upper := strings.ToUpper(r)
	switch upper {
	case "EU":
		return "EU"
	case "US-CENTRAL":
		return "US-central"
	case "US-EAST":
		return "US-east"
	case "US-WEST":
		return "US-west"
	case "SIN":
		return "SIN"
	case "UK":
		return "UK"
	case "AUS":
		return "AUS"
	case "JPN":
		return "JPN"
	case "IND":
		return "IND"
	}
	switch strings.ToLower(r) {
	case "us-central", "uscentral":
		return "US-central"
	case "us-east", "useast":
		return "US-east"
	case "us-west", "uswest":
		return "US-west"
	case "eu", "europe":
		return "EU"
	case "sin", "singapore":
		return "SIN"
	case "uk":
		return "UK"
	case "aus", "australia":
		return "AUS"
	case "jpn", "japan":
		return "JPN"
	case "ind", "india":
		return "IND"
	default:
		return r
	}
}

func normalizeContaboPlanID(plan string) string {
	p := strings.TrimSpace(plan)
	if p == "" {
		return ""
	}
	upper := strings.ToUpper(p)
	switch upper {
	case "V91", "V92", "V93", "V94", "V95", "V96", "V97", "V98", "V99", "V100", "V101", "V102", "V103", "V104", "V105", "V106", "V107":
		return upper
	case "VPS-10":
		return "V91"
	case "VPS-20":
		return "V92"
	case "VPS-30":
		return "V93"
	default:
		return p
	}
}

func oracleRegionFromAD(ad string) string {
	raw := strings.TrimSpace(ad)
	if raw == "" {
		return ""
	}
	if idx := strings.LastIndex(raw, ":"); idx > 0 {
		raw = raw[idx+1:]
	}
	token := strings.ToUpper(strings.TrimSpace(raw))
	if idx := strings.Index(token, "-AD-"); idx > 0 {
		token = token[:idx]
	}
	switch token {
	case "PHX":
		return "us-phoenix-1"
	case "IAD":
		return "us-ashburn-1"
	case "FRA":
		return "eu-frankfurt-1"
	case "LHR":
		return "uk-london-1"
	case "SIN":
		return "ap-singapore-1"
	case "NRT":
		return "ap-tokyo-1"
	default:
		return strings.ToLower(strings.TrimSpace(raw))
	}
}

func oracleRegionLocation(region string) (string, string) {
	switch strings.ToLower(strings.TrimSpace(region)) {
	case "us-ashburn-1":
		return "Ashburn", "United States"
	case "us-phoenix-1":
		return "Phoenix", "United States"
	case "eu-frankfurt-1":
		return "Frankfurt", "Germany"
	case "uk-london-1":
		return "London", "United Kingdom"
	case "ap-singapore-1":
		return "Singapore", "Singapore"
	case "ap-tokyo-1":
		return "Tokyo", "Japan"
	default:
		return "", ""
	}
}

func zoneToContinent(zone string) string {
	z := strings.ToLower(strings.TrimSpace(zone))
	switch {
	case strings.HasPrefix(z, "eu"):
		return "Europe"
	case strings.HasPrefix(z, "us"):
		return "North America"
	case strings.HasPrefix(z, "ap"):
		return "Asia"
	default:
		return "Unknown"
	}
}

func continentFromCountry(country string) string {
	switch strings.ToUpper(strings.TrimSpace(country)) {
	case "US", "CA", "MX":
		return "North America"
	case "DE", "FR", "NL", "GB", "PL", "FI", "SE", "NO", "ES", "IT", "IE":
		return "Europe"
	case "SG", "JP", "HK", "KR", "IN", "ID", "TH":
		return "Asia"
	case "AU", "NZ":
		return "Oceania"
	default:
		return "Unknown"
	}
}
