package catalog

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

func (p *Provider) upcloudTemplateStorageID(ctx context.Context) (string, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return "", err
	}
	obj := parseAPIKeyObject(cfg.APIKey)
	template := firstNonEmpty(
		strings.TrimSpace(cfg.Extra["templateStorage"]),
		strings.TrimSpace(cfg.Extra["template_storage"]),
		strings.TrimSpace(cfg.Extra["image"]),
		strings.TrimSpace(cfg.Extra["imageId"]),
		lookupMapValue(obj, "templatestorage", "template_storage", "image", "imageid"),
	)
	if template != "" {
		return template, nil
	}

	candidates := []string{"/storage/template", "/storage/template?public=yes", "/storage/template?access=public"}
	for _, path := range candidates {
		status, body, err := p.apiRequest(ctx, http.MethodGet, path, nil)
		if err != nil {
			continue
		}
		if status != http.StatusOK {
			continue
		}
		var payload struct {
			Storages struct {
				Storage []struct {
					UUID  string `json:"uuid"`
					Title string `json:"title"`
					Type  string `json:"type"`
				} `json:"storage"`
			} `json:"storages"`
			Templates struct {
				StorageTemplate []struct {
					UUID  string `json:"uuid"`
					Title string `json:"title"`
					Type  string `json:"type"`
				} `json:"storage_template"`
			} `json:"storage_templates"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			continue
		}

		search := func(entries []struct {
			UUID  string `json:"uuid"`
			Title string `json:"title"`
			Type  string `json:"type"`
		}) string {
			pick := ""
			for _, item := range entries {
				id := strings.TrimSpace(item.UUID)
				if id == "" {
					continue
				}
				title := strings.ToLower(strings.TrimSpace(item.Title))
				if strings.Contains(title, "ubuntu") && (strings.Contains(title, "22.04") || strings.Contains(title, "24.04")) {
					return id
				}
				if pick == "" {
					pick = id
				}
			}
			return pick
		}
		if id := search(payload.Storages.Storage); id != "" {
			return id, nil
		}
		if id := search(payload.Templates.StorageTemplate); id != "" {
			return id, nil
		}
	}

	return "", fmt.Errorf("upcloud template storage not found; set extra.templateStorage with a template UUID")
}
