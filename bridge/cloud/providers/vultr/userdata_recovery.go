package vultr

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"privatedeploy/bridge/cloud"
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

func (p *Provider) recoverNodeRecordForInstance(ctx context.Context, inst vultrInstance, record nodeRecord) (nodeRecord, bool) {
	script, err := p.getInstanceUserData(ctx, inst.ID)
	if err != nil || strings.TrimSpace(script) == "" {
		return record, false
	}

	recovered := record
	if !cloud.RecoverInstanceRecordFromUserData(script, &recovered.InstanceRecord) {
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
