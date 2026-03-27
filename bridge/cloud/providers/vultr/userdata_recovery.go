package vultr

import (
	"context"
	"encoding/base64"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

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
)

func (p *Provider) getInstanceUserData(ctx context.Context, instanceID string) (string, error) {
	res, err := p.apiRequest(ctx, "GET", "/instances/"+instanceID+"/user-data", nil)
	if err != nil {
		return "", err
	}

	var payload map[string]any
	if err := p.parseResponse(res, &payload); err != nil {
		return "", err
	}

	encoded := decodeUserDataPayload(payload)
	if strings.TrimSpace(encoded) == "" {
		return "", nil
	}

	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", fmt.Errorf("decode user-data: %w", err)
	}
	return string(decoded), nil
}

func decodeUserDataPayload(payload map[string]any) string {
	if payload == nil {
		return ""
	}

	raw := payload["user_data"]
	switch typed := raw.(type) {
	case string:
		return strings.TrimSpace(typed)
	case map[string]any:
		value, _ := typed["data"].(string)
		return strings.TrimSpace(value)
	case map[string]string:
		return strings.TrimSpace(typed["data"])
	default:
		return ""
	}
}

func shouldRecoverNodeRecord(record nodeRecord) bool {
	return !validateNodeRecord(record)
}

func recoverNodeRecordFromUserData(script string, base nodeRecord) (nodeRecord, bool) {
	record := base
	changed := false

	if match := recoveredSSConfig.FindStringSubmatch(script); len(match) > 0 {
		if setInt(&record.SSPort, parseInt(match[1])) {
			changed = true
		}
		if record.Port != record.SSPort {
			record.Port = record.SSPort
			changed = true
		}
		password := firstNonEmpty(match[2], match[3], match[4])
		if setString(&record.SSPassword, password) {
			changed = true
		}
		if setString(&record.Password, password) {
			changed = true
		}
	}

	if setInt(&record.HysteriaPort, parseInt(firstMatchGroup(recoveredHysteriaPort, script, 1))) {
		changed = true
	}
	if setString(&record.HysteriaPassword, firstNonEmpty(
		firstMatchGroup(recoveredHysteriaPasswordEnv, script, 1),
		firstMatchGroup(recoveredHysteriaPasswordEnv, script, 2),
		firstMatchGroup(recoveredHysteriaPasswordEnv, script, 3),
		firstMatchGroup(recoveredHysteriaPasswordJSON, script, 1),
	)) {
		changed = true
	}
	if setString(&record.HysteriaServerName, firstNonEmpty(
		firstMatchGroup(recoveredHysteriaServerEnv, script, 1),
		firstMatchGroup(recoveredHysteriaServerEnv, script, 2),
		firstMatchGroup(recoveredHysteriaServerEnv, script, 3),
		firstMatchGroup(recoveredHysteriaServerJSON, script, 1),
	)) {
		changed = true
	}

	if setInt(&record.VLESSPort, parseInt(firstMatchGroup(recoveredVLESSPort, script, 1))) {
		changed = true
	}
	if setString(&record.VLESSUUID, firstMatchGroup(recoveredVLESSUUID, script, 1)) {
		changed = true
	}
	if setString(&record.VLESSPublicKey, firstMatchGroup(recoveredVLESSPublicKey, script, 1)) {
		changed = true
	}
	if setString(&record.VLESSShortID, firstNonEmpty(
		firstMatchGroup(recoveredVLESSShortIDTxt, script, 1),
		firstMatchGroup(recoveredVLESSShortIDCfg, script, 1),
	)) {
		changed = true
	}
	if setString(&record.VLESSServerName, firstMatchGroup(recoveredVLESSServerName, script, 1)) {
		changed = true
	}

	if setInt(&record.TrojanPort, parseInt(firstMatchGroup(recoveredTrojanPort, script, 1))) {
		changed = true
	}
	if setString(&record.TrojanPassword, firstMatchGroup(recoveredTrojanPassword, script, 1)) {
		changed = true
	}
	if setString(&record.TrojanServerName, firstMatchGroup(recoveredTrojanServerName, script, 1)) {
		changed = true
	}

	if ensureManagedTLSDefaults(&record.InstanceRecord) {
		changed = true
	}

	return record, changed && validateNodeRecord(record)
}

func (p *Provider) recoverNodeRecordForInstance(ctx context.Context, inst vultrInstance, record nodeRecord) (nodeRecord, bool) {
	script, err := p.getInstanceUserData(ctx, inst.ID)
	if err != nil || strings.TrimSpace(script) == "" {
		return record, false
	}

	recovered, ok := recoverNodeRecordFromUserData(script, record)
	if !ok {
		return record, false
	}

	if strings.TrimSpace(recovered.InstanceID) == "" {
		recovered.InstanceID = inst.ID
	}
	if strings.TrimSpace(inst.Label) != "" {
		recovered.Label = inst.Label
	}
	if strings.TrimSpace(inst.Region) != "" {
		recovered.Region = inst.Region
	}
	if strings.TrimSpace(inst.MainIP) != "" {
		recovered.IPv4 = inst.MainIP
	}
	if strings.TrimSpace(inst.V6MainIP) != "" {
		recovered.IPv6 = inst.V6MainIP
	}
	if strings.TrimSpace(recovered.CreatedAt) == "" && strings.TrimSpace(inst.CreatedAt) != "" {
		recovered.CreatedAt = inst.CreatedAt
	}
	return recovered, true
}

func firstMatchGroup(pattern *regexp.Regexp, input string, group int) string {
	match := pattern.FindStringSubmatch(input)
	if len(match) <= group {
		return ""
	}
	return match[group]
}

func parseInt(value string) int {
	result, _ := strconv.Atoi(strings.TrimSpace(value))
	return result
}

func setString(target *string, value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || *target == value {
		return false
	}
	*target = value
	return true
}

func setInt(target *int, value int) bool {
	if value <= 0 || *target == value {
		return false
	}
	*target = value
	return true
}
