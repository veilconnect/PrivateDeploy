package catalog

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"privatedeploy/bridge/cloud"
	"strings"
)

func (p *Provider) scalewayProjectID(ctx context.Context) (string, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return "", err
	}
	obj := parseAPIKeyObject(cfg.APIKey)
	projectID := firstNonEmpty(
		strings.TrimSpace(cfg.Extra["project"]),
		strings.TrimSpace(cfg.Extra["projectId"]),
		strings.TrimSpace(cfg.Extra["project_id"]),
		lookupMapValue(obj, "project", "projectid", "project_id"),
	)
	if projectID != "" {
		return projectID, nil
	}

	status, body, err := p.apiRequest(ctx, http.MethodGet, "/account/v1/projects", nil)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("failed to resolve scaleway project: status=%d body=%s", status, strings.TrimSpace(string(body)))
	}
	var payload struct {
		Projects []struct {
			ID string `json:"id"`
		} `json:"projects"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}
	if len(payload.Projects) == 0 || strings.TrimSpace(payload.Projects[0].ID) == "" {
		return "", fmt.Errorf("failed to resolve scaleway project: no project found for token")
	}
	return strings.TrimSpace(payload.Projects[0].ID), nil
}

func (p *Provider) scalewayImageID(ctx context.Context, zone string) (string, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return "", err
	}
	obj := parseAPIKeyObject(cfg.APIKey)
	imageID := firstNonEmpty(
		strings.TrimSpace(cfg.Extra["image"]),
		strings.TrimSpace(cfg.Extra["imageId"]),
		strings.TrimSpace(cfg.Extra["image_id"]),
		lookupMapValue(obj, "image", "imageid", "image_id"),
	)
	if imageID != "" {
		return imageID, nil
	}

	path := fmt.Sprintf("/instance/v1/zones/%s/images?page=1&per_page=100", url.PathEscape(zone))
	status, body, err := p.apiRequest(ctx, http.MethodGet, path, nil)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("failed to resolve scaleway image: status=%d body=%s", status, strings.TrimSpace(string(body)))
	}
	var payload struct {
		Images []struct {
			ID     string `json:"id"`
			Name   string `json:"name"`
			Public bool   `json:"public"`
		} `json:"images"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}

	pick := ""
	for _, img := range payload.Images {
		if strings.TrimSpace(img.ID) == "" || !img.Public {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(img.Name))
		if strings.Contains(name, "ubuntu") && (strings.Contains(name, "22.04") || strings.Contains(name, "jammy") || strings.Contains(name, "24.04") || strings.Contains(name, "noble")) {
			return strings.TrimSpace(img.ID), nil
		}
		if pick == "" {
			pick = strings.TrimSpace(img.ID)
		}
	}
	if pick == "" {
		return "", fmt.Errorf("failed to resolve scaleway image: no public image found")
	}
	return pick, nil
}

func (p *Provider) scalewayGetInstance(ctx context.Context, remoteID string) (remoteInstance, error) {
	candidates := make([]string, 0, 1)
	serverID := strings.TrimSpace(remoteID)
	if zone, id, ok := parseScopedRemoteID(remoteID); ok {
		candidates = append(candidates, zone)
		serverID = id
	} else {
		candidates = append(candidates, p.regionIDs()...)
	}

	for _, zone := range candidates {
		path := fmt.Sprintf("/instance/v1/zones/%s/servers/%s", url.PathEscape(zone), url.PathEscape(serverID))
		status, body, err := p.apiRequest(ctx, http.MethodGet, path, nil)
		if err != nil {
			return remoteInstance{}, err
		}
		if status == http.StatusNotFound {
			continue
		}
		if status != http.StatusOK {
			return remoteInstance{}, fmt.Errorf("get scaleway server failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var result struct {
			Server struct {
				ID             string `json:"id"`
				Name           string `json:"name"`
				State          string `json:"state"`
				CreationDate   string `json:"creation_date"`
				Zone           string `json:"zone"`
				CommercialType string `json:"commercial_type"`
				PublicIP       *struct {
					Address string `json:"address"`
				} `json:"public_ip"`
				IPv6 *struct {
					Address string `json:"address"`
				} `json:"ipv6"`
			} `json:"server"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		ipv4 := ""
		if result.Server.PublicIP != nil {
			ipv4 = strings.TrimSpace(result.Server.PublicIP.Address)
		}
		ipv6 := ""
		if result.Server.IPv6 != nil {
			ipv6 = strings.TrimSpace(result.Server.IPv6.Address)
		}
		actualZone := firstNonEmpty(strings.TrimSpace(result.Server.Zone), zone)
		raw := scopedRemoteID(actualZone, strings.TrimSpace(result.Server.ID))
		return remoteInstance{
			RawID:     raw,
			ID:        p.cloudID(raw),
			Label:     firstNonEmpty(result.Server.Name, "node"),
			Status:    result.Server.State,
			Region:    actualZone,
			Plan:      result.Server.CommercialType,
			IPv4:      ipv4,
			IPv6:      ipv6,
			CreatedAt: parseRFC3339(result.Server.CreationDate),
		}, nil
	}

	return remoteInstance{}, cloud.ErrInstanceNotFound
}
