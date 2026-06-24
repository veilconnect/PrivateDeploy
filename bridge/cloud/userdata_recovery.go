package cloud

import (
	"regexp"
	"strconv"
	"strings"
)

// Recovery parsers for reconstructing a node's InstanceRecord from the deploy
// script that provisioned it (cloud-init user-data). Used when the local node
// record is lost (fresh device, CLI-created node, corrupted state). The script
// format is shared across providers, so this lives in the cloud package and is
// reused by every provider that can retrieve a node's user-data (Vultr via API,
// DigitalOcean via SSH).
var (
	recoveredSSConfig = regexp.MustCompile(`-s 0\.0\.0\.0 -p (\d+) -k (?:"([^"]+)"|'([^']+)'|([^\s]+)) -m aes-256-gcm`)

	recoveredHysteriaPort         = regexp.MustCompile(`(?s)"type":\s*"hysteria2".*?"listen_port":\s*(\d+)`)
	recoveredHysteriaPasswordJSON = regexp.MustCompile(`(?s)"type":\s*"hysteria2".*?"password":\s*"([^"]+)"`)
	recoveredHysteriaPasswordEnv  = regexp.MustCompile(`(?m)^HYSTERIA_PASSWORD=(?:"([^"]+)"|'([^']+)'|([^\s]+))$`)
	recoveredHysteriaServerJSON   = regexp.MustCompile(`(?s)"type":\s*"hysteria2".*?"server_name":\s*"([^"]+)"`)
	recoveredHysteriaServerEnv    = regexp.MustCompile(`(?m)^HYSTERIA_SERVER_NAME=(?:"([^"]+)"|'([^']+)'|([^\s]+))$`)

	recoveredVLESSPort       = regexp.MustCompile(`(?s)"type":\s*"vless".*?"listen_port":\s*(\d+)`)
	recoveredVLESSUUID       = regexp.MustCompile(`(?s)"type":\s*"vless".*?"uuid":\s*"([^"]+)"`)
	recoveredVLESSServerName = regexp.MustCompile(`(?s)"type":\s*"vless".*?"server_name":\s*"([^"]+)"`)
	recoveredVLESSPublicKey  = regexp.MustCompile(`(?m)^PublicKey:\s*([A-Za-z0-9_-]+)$`)
	recoveredVLESSShortIDTxt = regexp.MustCompile(`(?m)^ShortID:\s*([A-Za-z0-9]+)$`)
	recoveredVLESSShortIDCfg = regexp.MustCompile(`(?s)"short_id":\s*\[\s*"([^"]+)"\s*\]`)

	recoveredTrojanPort       = regexp.MustCompile(`(?s)"type":\s*"trojan".*?"listen_port":\s*(\d+)`)
	recoveredTrojanPassword   = regexp.MustCompile(`(?s)"type":\s*"trojan".*?"password":\s*"([^"]+)"`)
	recoveredTrojanServerName = regexp.MustCompile(`(?s)"type":\s*"trojan".*?"server_name":\s*"([^"]+)"`)

	// VLESS relay (CDN-front) port. The install script always pairs the
	// relay-port ufw rule with the "VLESS-Relay (CDN)" comment, a stable signal
	// that survives port-number changes. Matches both `ufw allow` and
	// `ufw limit` (the script flipped allow→limit in a later revision).
	recoveredVLESSRelayPort = regexp.MustCompile(`ufw\s+(?:allow|limit)\s+(\d+)/tcp\s+comment\s+'VLESS-Relay`)
)

// RecoverInstanceRecordFromUserData parses a deploy script and fills any missing
// fields on rec in place. It returns true only when the parse both changed rec
// and produced a record with at least a usable Shadowsocks config — i.e. the
// recovery is trustworthy enough to persist.
func RecoverInstanceRecordFromUserData(script string, rec *InstanceRecord) bool {
	if rec == nil {
		return false
	}
	changed := false

	if match := recoveredSSConfig.FindStringSubmatch(script); len(match) > 0 {
		if recSetInt(&rec.SSPort, recParseInt(match[1])) {
			changed = true
		}
		if rec.Port != rec.SSPort {
			rec.Port = rec.SSPort
			changed = true
		}
		password := recFirstNonEmpty(match[2], match[3], match[4])
		if recSetString(&rec.SSPassword, password) {
			changed = true
		}
		if recSetString(&rec.Password, password) {
			changed = true
		}
	}

	if recSetInt(&rec.HysteriaPort, recParseInt(recFirstGroup(recoveredHysteriaPort, script, 1))) {
		changed = true
	}
	if recSetString(&rec.HysteriaPassword, recFirstNonEmpty(
		recFirstGroup(recoveredHysteriaPasswordEnv, script, 1),
		recFirstGroup(recoveredHysteriaPasswordEnv, script, 2),
		recFirstGroup(recoveredHysteriaPasswordEnv, script, 3),
		recFirstGroup(recoveredHysteriaPasswordJSON, script, 1),
	)) {
		changed = true
	}
	if recSetString(&rec.HysteriaServerName, recFirstNonEmpty(
		recFirstGroup(recoveredHysteriaServerEnv, script, 1),
		recFirstGroup(recoveredHysteriaServerEnv, script, 2),
		recFirstGroup(recoveredHysteriaServerEnv, script, 3),
		recFirstGroup(recoveredHysteriaServerJSON, script, 1),
	)) {
		changed = true
	}

	if recSetInt(&rec.VLESSPort, recParseInt(recFirstGroup(recoveredVLESSPort, script, 1))) {
		changed = true
	}
	if recSetString(&rec.VLESSUUID, recFirstGroup(recoveredVLESSUUID, script, 1)) {
		changed = true
	}
	if recSetString(&rec.VLESSPublicKey, recFirstGroup(recoveredVLESSPublicKey, script, 1)) {
		changed = true
	}
	if recSetString(&rec.VLESSShortID, recFirstNonEmpty(
		recFirstGroup(recoveredVLESSShortIDTxt, script, 1),
		recFirstGroup(recoveredVLESSShortIDCfg, script, 1),
	)) {
		changed = true
	}
	if recSetString(&rec.VLESSServerName, recFirstGroup(recoveredVLESSServerName, script, 1)) {
		changed = true
	}
	if recSetInt(&rec.VLESSRelayPort, recParseInt(recFirstGroup(recoveredVLESSRelayPort, script, 1))) {
		changed = true
	}

	if recSetInt(&rec.TrojanPort, recParseInt(recFirstGroup(recoveredTrojanPort, script, 1))) {
		changed = true
	}
	if recSetString(&rec.TrojanPassword, recFirstGroup(recoveredTrojanPassword, script, 1)) {
		changed = true
	}
	if recSetString(&rec.TrojanServerName, recFirstGroup(recoveredTrojanServerName, script, 1)) {
		changed = true
	}

	if EnsureManagedTLSDefaults(rec) {
		changed = true
	}

	return changed && HasMinimumProxyConfig(*rec)
}

func recFirstGroup(pattern *regexp.Regexp, input string, group int) string {
	match := pattern.FindStringSubmatch(input)
	if len(match) <= group {
		return ""
	}
	return match[group]
}

func recParseInt(value string) int {
	result, _ := strconv.Atoi(strings.TrimSpace(value))
	return result
}

func recFirstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func recSetString(target *string, value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || *target == value {
		return false
	}
	*target = value
	return true
}

func recSetInt(target *int, value int) bool {
	if value <= 0 || *target == value {
		return false
	}
	*target = value
	return true
}
