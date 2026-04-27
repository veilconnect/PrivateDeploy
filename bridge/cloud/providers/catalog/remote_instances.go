package catalog

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"strconv"
	"strings"
	"time"
)

func (p *Provider) listRemoteInstances(ctx context.Context) ([]remoteInstance, error) {
	switch p.name {
	case "hetzner":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/servers", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list servers failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Servers []struct {
				ID         int    `json:"id"`
				Name       string `json:"name"`
				Status     string `json:"status"`
				Created    string `json:"created"`
				ServerType struct {
					Name string `json:"name"`
				} `json:"server_type"`
				Datacenter struct {
					Location struct {
						Name string `json:"name"`
					} `json:"location"`
				} `json:"datacenter"`
				PublicNet struct {
					IPv4 struct {
						IP string `json:"ip"`
					} `json:"ipv4"`
					IPv6 struct {
						IP string `json:"ip"`
					} `json:"ipv6"`
				} `json:"public_net"`
			} `json:"servers"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		out := make([]remoteInstance, 0, len(payload.Servers))
		for _, s := range payload.Servers {
			raw := strconv.Itoa(s.ID)
			out = append(out, remoteInstance{
				RawID:     raw,
				ID:        p.cloudID(raw),
				Label:     s.Name,
				Status:    s.Status,
				Region:    s.Datacenter.Location.Name,
				Plan:      s.ServerType.Name,
				IPv4:      strings.TrimSpace(s.PublicNet.IPv4.IP),
				IPv6:      strings.TrimSpace(s.PublicNet.IPv6.IP),
				CreatedAt: parseRFC3339(s.Created),
			})
		}
		return out, nil
	case "linode":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/linode/instances", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list linode instances failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Data []struct {
				ID      int      `json:"id"`
				Label   string   `json:"label"`
				Status  string   `json:"status"`
				Region  string   `json:"region"`
				Type    string   `json:"type"`
				IPv4    []string `json:"ipv4"`
				IPv6    string   `json:"ipv6"`
				Created string   `json:"created"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		out := make([]remoteInstance, 0, len(payload.Data))
		for _, s := range payload.Data {
			raw := strconv.Itoa(s.ID)
			out = append(out, remoteInstance{
				RawID:     raw,
				ID:        p.cloudID(raw),
				Label:     s.Label,
				Status:    s.Status,
				Region:    s.Region,
				Plan:      s.Type,
				IPv4:      firstPublicIPv4(s.IPv4),
				IPv6:      strings.TrimSpace(s.IPv6),
				CreatedAt: parseRFC3339(s.Created),
			})
		}
		return out, nil
	case "scaleway":
		zones := p.regionIDs()
		out := make([]remoteInstance, 0, len(zones))
		seen := map[string]struct{}{}
		for _, zone := range zones {
			path := fmt.Sprintf("/instance/v1/zones/%s/servers", url.PathEscape(zone))
			status, body, err := p.apiRequest(ctx, http.MethodGet, path, nil)
			if err != nil {
				return nil, err
			}
			if status == http.StatusNotFound {
				continue
			}
			if status != http.StatusOK {
				return nil, fmt.Errorf("list scaleway servers failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
			}
			var payload struct {
				Servers []struct {
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
				} `json:"servers"`
			}
			if err := json.Unmarshal(body, &payload); err != nil {
				return nil, err
			}
			for _, s := range payload.Servers {
				serverID := strings.TrimSpace(s.ID)
				if serverID == "" {
					continue
				}
				raw := scopedRemoteID(firstNonEmpty(strings.TrimSpace(s.Zone), zone), serverID)
				if _, ok := seen[raw]; ok {
					continue
				}
				seen[raw] = struct{}{}
				ipv4 := ""
				if s.PublicIP != nil {
					ipv4 = strings.TrimSpace(s.PublicIP.Address)
				}
				ipv6 := ""
				if s.IPv6 != nil {
					ipv6 = strings.TrimSpace(s.IPv6.Address)
				}
				out = append(out, remoteInstance{
					RawID:     raw,
					ID:        p.cloudID(raw),
					Label:     s.Name,
					Status:    s.State,
					Region:    firstNonEmpty(strings.TrimSpace(s.Zone), zone),
					Plan:      s.CommercialType,
					IPv4:      ipv4,
					IPv6:      ipv6,
					CreatedAt: parseRFC3339(s.CreationDate),
				})
			}
		}
		return out, nil
	case "upcloud":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/server", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list upcloud servers failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Servers struct {
				Server []struct {
					UUID      string `json:"uuid"`
					Title     string `json:"title"`
					Hostname  string `json:"hostname"`
					State     string `json:"state"`
					Zone      string `json:"zone"`
					Plan      string `json:"plan"`
					CreatedAt string `json:"created"`
					IPList    struct {
						Items []struct {
							Address string `json:"address"`
							Family  string `json:"family"`
							Access  string `json:"access"`
						} `json:"ip_address"`
					} `json:"ip_addresses"`
				} `json:"server"`
			} `json:"servers"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		out := make([]remoteInstance, 0, len(payload.Servers.Server))
		for _, s := range payload.Servers.Server {
			serverID := strings.TrimSpace(s.UUID)
			if serverID == "" {
				continue
			}
			ipv4, ipv6 := upcloudIPs(s.IPList.Items)
			out = append(out, remoteInstance{
				RawID:     serverID,
				ID:        p.cloudID(serverID),
				Label:     firstNonEmpty(s.Title, s.Hostname),
				Status:    s.State,
				Region:    s.Zone,
				Plan:      s.Plan,
				IPv4:      ipv4,
				IPv6:      ipv6,
				CreatedAt: parseRFC3339(s.CreatedAt),
			})
		}
		return out, nil
	case "contabo":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/v1/compute/instances", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list contabo instances failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Data []map[string]any `json:"data"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		out := make([]remoteInstance, 0, len(payload.Data))
		for _, item := range payload.Data {
			raw := anyToString(item["instanceId"])
			if strings.TrimSpace(raw) == "" {
				continue
			}
			label := firstNonEmpty(anyToString(item["displayName"]), anyToString(item["name"]), "node")
			region := firstNonEmpty(anyToString(item["region"]), anyToString(item["regionName"]))
			plan := anyToString(item["productId"])
			statusText := normalizeStatus(item["status"])
			createdAt := parseRFC3339(anyToString(item["createdDate"]))
			ipv4, ipv6 := contaboIPConfig(item["ipConfig"])

			out = append(out, remoteInstance{
				RawID:     raw,
				ID:        p.cloudID(raw),
				Label:     label,
				Status:    statusText,
				Region:    region,
				Plan:      plan,
				IPv4:      ipv4,
				IPv6:      ipv6,
				CreatedAt: createdAt,
			})
		}
		return out, nil
	case "oracle":
		return p.oracleListInstances(ctx)
	default:
		return nil, fmt.Errorf("provider %s does not support lifecycle", p.name)
	}
}

func (p *Provider) createRemoteInstance(ctx context.Context, label, region, plan, userData string) (remoteInstance, error) {
	switch p.name {
	case "hetzner":
		payload := map[string]any{
			"name":               label,
			"server_type":        plan,
			"image":              catalogDefaultCreateImageHZ,
			"location":           region,
			"user_data":          userData,
			"start_after_create": true,
		}
		status, body, err := p.apiRequest(ctx, http.MethodPost, "/servers", payload)
		if err != nil {
			return remoteInstance{}, err
		}
		if status != http.StatusCreated && status != http.StatusAccepted {
			return remoteInstance{}, fmt.Errorf("create hetzner server failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var result struct {
			Server struct {
				ID         int    `json:"id"`
				Name       string `json:"name"`
				Status     string `json:"status"`
				Created    string `json:"created"`
				ServerType struct {
					Name string `json:"name"`
				} `json:"server_type"`
				Datacenter struct {
					Location struct {
						Name string `json:"name"`
					} `json:"location"`
				} `json:"datacenter"`
				PublicNet struct {
					IPv4 struct {
						IP string `json:"ip"`
					} `json:"ipv4"`
					IPv6 struct {
						IP string `json:"ip"`
					} `json:"ipv6"`
				} `json:"public_net"`
			} `json:"server"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := strconv.Itoa(result.Server.ID)
		return remoteInstance{RawID: raw, ID: p.cloudID(raw), Label: result.Server.Name, Status: result.Server.Status, Region: result.Server.Datacenter.Location.Name, Plan: result.Server.ServerType.Name, IPv4: result.Server.PublicNet.IPv4.IP, IPv6: result.Server.PublicNet.IPv6.IP, CreatedAt: parseRFC3339(result.Server.Created)}, nil
	case "linode":
		rootPass := deploy.GenerateRandomPassword(26)
		payload := map[string]any{
			"label":     label,
			"region":    region,
			"type":      plan,
			"image":     catalogDefaultCreateImageLI,
			"root_pass": rootPass,
			"booted":    true,
			"metadata": map[string]any{
				"user_data": base64.StdEncoding.EncodeToString([]byte(userData)),
			},
		}
		status, body, err := p.apiRequest(ctx, http.MethodPost, "/linode/instances", payload)
		if err != nil {
			return remoteInstance{}, err
		}
		if status != http.StatusOK && status != http.StatusCreated {
			return remoteInstance{}, fmt.Errorf("create linode instance failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var result struct {
			ID      int      `json:"id"`
			Label   string   `json:"label"`
			Status  string   `json:"status"`
			Region  string   `json:"region"`
			Type    string   `json:"type"`
			IPv4    []string `json:"ipv4"`
			IPv6    string   `json:"ipv6"`
			Created string   `json:"created"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := strconv.Itoa(result.ID)
		return remoteInstance{RawID: raw, ID: p.cloudID(raw), Label: result.Label, Status: result.Status, Region: result.Region, Plan: result.Type, IPv4: firstPublicIPv4(result.IPv4), IPv6: result.IPv6, CreatedAt: parseRFC3339(result.Created)}, nil
	case "scaleway":
		projectID, err := p.scalewayProjectID(ctx)
		if err != nil {
			return remoteInstance{}, err
		}
		imageID, err := p.scalewayImageID(ctx, region)
		if err != nil {
			return remoteInstance{}, err
		}
		payload := map[string]any{
			"name":                label,
			"commercial_type":     plan,
			"image":               imageID,
			"project":             projectID,
			"enable_ipv6":         true,
			"dynamic_ip_required": true,
			"cloud_init":          userData,
		}
		path := fmt.Sprintf("/instance/v1/zones/%s/servers", url.PathEscape(region))
		status, body, err := p.apiRequest(ctx, http.MethodPost, path, payload)
		if err != nil {
			return remoteInstance{}, err
		}
		if status != http.StatusCreated && status != http.StatusAccepted && status != http.StatusOK {
			return remoteInstance{}, fmt.Errorf("create scaleway server failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
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
		serverID := strings.TrimSpace(result.Server.ID)
		if serverID == "" {
			return remoteInstance{}, fmt.Errorf("scaleway create did not return server id")
		}
		zone := firstNonEmpty(strings.TrimSpace(result.Server.Zone), region)
		raw := scopedRemoteID(zone, serverID)
		_, _, _ = p.apiRequest(ctx, http.MethodPost, fmt.Sprintf("/instance/v1/zones/%s/servers/%s/action", url.PathEscape(zone), url.PathEscape(serverID)), map[string]any{"action": "poweron"})

		if refreshed, err := p.getRemoteInstance(ctx, raw); err == nil {
			return refreshed, nil
		}
		ipv4 := ""
		if result.Server.PublicIP != nil {
			ipv4 = strings.TrimSpace(result.Server.PublicIP.Address)
		}
		ipv6 := ""
		if result.Server.IPv6 != nil {
			ipv6 = strings.TrimSpace(result.Server.IPv6.Address)
		}
		return remoteInstance{
			RawID:     raw,
			ID:        p.cloudID(raw),
			Label:     firstNonEmpty(result.Server.Name, label),
			Status:    firstNonEmpty(result.Server.State, "starting"),
			Region:    zone,
			Plan:      firstNonEmpty(result.Server.CommercialType, plan),
			IPv4:      ipv4,
			IPv6:      ipv6,
			CreatedAt: parseRFC3339(result.Server.CreationDate),
		}, nil
	case "upcloud":
		templateStorage, err := p.upcloudTemplateStorageID(ctx)
		if err != nil {
			return remoteInstance{}, err
		}
		rootPass := deploy.GenerateRandomPassword(24)
		payload := map[string]any{
			"server": map[string]any{
				"zone":              region,
				"title":             label,
				"hostname":          safeHostname(label, "pd-upcloud"),
				"plan":              plan,
				"password":          rootPass,
				"password_delivery": "none",
				"user_data":         base64.StdEncoding.EncodeToString([]byte(userData)),
				"storage_devices": map[string]any{
					"storage_device": []map[string]any{
						{
							"action":  "clone",
							"storage": templateStorage,
							"title":   "Root disk",
							"size":    25,
							"tier":    "maxiops",
						},
					},
				},
				"networking": map[string]any{
					"interfaces": map[string]any{
						"interface": []map[string]any{
							{"type": "public"},
						},
					},
				},
			},
		}
		status, body, err := p.apiRequest(ctx, http.MethodPost, "/server", payload)
		if err != nil {
			return remoteInstance{}, err
		}
		if status != http.StatusCreated && status != http.StatusAccepted && status != http.StatusOK {
			return remoteInstance{}, fmt.Errorf("create upcloud server failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var result struct {
			Server struct {
				UUID      string `json:"uuid"`
				Title     string `json:"title"`
				Hostname  string `json:"hostname"`
				State     string `json:"state"`
				Zone      string `json:"zone"`
				Plan      string `json:"plan"`
				CreatedAt string `json:"created"`
				IPList    struct {
					Items []struct {
						Address string `json:"address"`
						Family  string `json:"family"`
						Access  string `json:"access"`
					} `json:"ip_address"`
				} `json:"ip_addresses"`
			} `json:"server"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		serverID := strings.TrimSpace(result.Server.UUID)
		if serverID == "" {
			return remoteInstance{}, fmt.Errorf("upcloud create did not return server uuid")
		}
		ipv4, ipv6 := upcloudIPs(result.Server.IPList.Items)
		return remoteInstance{
			RawID:     serverID,
			ID:        p.cloudID(serverID),
			Label:     firstNonEmpty(result.Server.Title, result.Server.Hostname, label),
			Status:    firstNonEmpty(result.Server.State, "started"),
			Region:    firstNonEmpty(result.Server.Zone, region),
			Plan:      firstNonEmpty(result.Server.Plan, plan),
			IPv4:      ipv4,
			IPv6:      ipv6,
			CreatedAt: parseRFC3339(result.Server.CreatedAt),
		}, nil
	case "contabo":
		productID := normalizeContaboPlanID(plan)
		if productID == "" {
			productID = "V92"
		}
		regionID := normalizeContaboRegion(region)
		if regionID == "" {
			regionID = "EU"
		}
		payload := map[string]any{
			"period":      1,
			"productId":   productID,
			"region":      regionID,
			"displayName": label,
			"userData":    userData,
			"defaultUser": "root",
		}
		status, body, err := p.apiRequest(ctx, http.MethodPost, "/v1/compute/instances", payload)
		if err != nil {
			return remoteInstance{}, err
		}
		if status != http.StatusCreated && status != http.StatusAccepted && status != http.StatusOK {
			return remoteInstance{}, fmt.Errorf("create contabo instance failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var result struct {
			Data []map[string]any `json:"data"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := ""
		if len(result.Data) > 0 {
			raw = anyToString(result.Data[0]["instanceId"])
		}
		if strings.TrimSpace(raw) == "" {
			return remoteInstance{}, fmt.Errorf("contabo create did not return instance id")
		}
		if refreshed, err := p.getRemoteInstance(ctx, raw); err == nil {
			return refreshed, nil
		}
		return remoteInstance{
			RawID:     raw,
			ID:        p.cloudID(raw),
			Label:     label,
			Status:    "creating",
			Region:    regionID,
			Plan:      productID,
			CreatedAt: time.Now().UTC(),
		}, nil
	case "oracle":
		return p.oracleCreateInstance(ctx, label, region, plan, userData)
	default:
		return remoteInstance{}, fmt.Errorf("provider %s does not support create", p.name)
	}
}

func (p *Provider) getRemoteInstance(ctx context.Context, remoteID string) (remoteInstance, error) {
	switch p.name {
	case "oracle":
		return p.oracleGetInstance(ctx, remoteID)
	case "scaleway":
		return p.scalewayGetInstance(ctx, remoteID)
	}

	path := p.remotePathForID(remoteID)
	if strings.TrimSpace(path) == "" {
		return remoteInstance{}, fmt.Errorf("provider %s does not support get path for id %q", p.name, remoteID)
	}

	status, body, err := p.apiRequest(ctx, http.MethodGet, path, nil)
	if err != nil {
		return remoteInstance{}, err
	}
	if status == http.StatusNotFound {
		_ = p.deleteNodeRecord(p.cloudID(remoteID))
		return remoteInstance{}, cloud.ErrInstanceNotFound
	}
	if status != http.StatusOK {
		return remoteInstance{}, fmt.Errorf("get instance failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
	}

	switch p.name {
	case "hetzner":
		var result struct {
			Server struct {
				ID         int    `json:"id"`
				Name       string `json:"name"`
				Status     string `json:"status"`
				Created    string `json:"created"`
				ServerType struct {
					Name string `json:"name"`
				} `json:"server_type"`
				Datacenter struct {
					Location struct {
						Name string `json:"name"`
					} `json:"location"`
				} `json:"datacenter"`
				PublicNet struct {
					IPv4 struct {
						IP string `json:"ip"`
					} `json:"ipv4"`
					IPv6 struct {
						IP string `json:"ip"`
					} `json:"ipv6"`
				} `json:"public_net"`
			} `json:"server"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := strconv.Itoa(result.Server.ID)
		return remoteInstance{RawID: raw, ID: p.cloudID(raw), Label: result.Server.Name, Status: result.Server.Status, Region: result.Server.Datacenter.Location.Name, Plan: result.Server.ServerType.Name, IPv4: result.Server.PublicNet.IPv4.IP, IPv6: result.Server.PublicNet.IPv6.IP, CreatedAt: parseRFC3339(result.Server.Created)}, nil
	case "linode":
		var result struct {
			ID      int      `json:"id"`
			Label   string   `json:"label"`
			Status  string   `json:"status"`
			Region  string   `json:"region"`
			Type    string   `json:"type"`
			IPv4    []string `json:"ipv4"`
			IPv6    string   `json:"ipv6"`
			Created string   `json:"created"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := strconv.Itoa(result.ID)
		return remoteInstance{RawID: raw, ID: p.cloudID(raw), Label: result.Label, Status: result.Status, Region: result.Region, Plan: result.Type, IPv4: firstPublicIPv4(result.IPv4), IPv6: result.IPv6, CreatedAt: parseRFC3339(result.Created)}, nil
	case "upcloud":
		var result struct {
			Server struct {
				UUID      string `json:"uuid"`
				Title     string `json:"title"`
				Hostname  string `json:"hostname"`
				State     string `json:"state"`
				Zone      string `json:"zone"`
				Plan      string `json:"plan"`
				CreatedAt string `json:"created"`
				IPList    struct {
					Items []struct {
						Address string `json:"address"`
						Family  string `json:"family"`
						Access  string `json:"access"`
					} `json:"ip_address"`
				} `json:"ip_addresses"`
			} `json:"server"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		raw := strings.TrimSpace(result.Server.UUID)
		if raw == "" {
			raw = strings.TrimSpace(remoteID)
		}
		ipv4, ipv6 := upcloudIPs(result.Server.IPList.Items)
		return remoteInstance{
			RawID:     raw,
			ID:        p.cloudID(raw),
			Label:     firstNonEmpty(result.Server.Title, result.Server.Hostname),
			Status:    result.Server.State,
			Region:    result.Server.Zone,
			Plan:      result.Server.Plan,
			IPv4:      ipv4,
			IPv6:      ipv6,
			CreatedAt: parseRFC3339(result.Server.CreatedAt),
		}, nil
	case "contabo":
		var result struct {
			Data []map[string]any `json:"data"`
		}
		if err := json.Unmarshal(body, &result); err != nil {
			return remoteInstance{}, err
		}
		if len(result.Data) == 0 {
			return remoteInstance{}, cloud.ErrInstanceNotFound
		}
		item := result.Data[0]
		raw := anyToString(item["instanceId"])
		if strings.TrimSpace(raw) == "" {
			raw = strings.TrimSpace(remoteID)
		}
		ipv4, ipv6 := contaboIPConfig(item["ipConfig"])
		return remoteInstance{
			RawID:     raw,
			ID:        p.cloudID(raw),
			Label:     firstNonEmpty(anyToString(item["displayName"]), anyToString(item["name"]), "node"),
			Status:    normalizeStatus(item["status"]),
			Region:    firstNonEmpty(anyToString(item["region"]), anyToString(item["regionName"])),
			Plan:      anyToString(item["productId"]),
			IPv4:      ipv4,
			IPv6:      ipv6,
			CreatedAt: parseRFC3339(anyToString(item["createdDate"])),
		}, nil
	default:
		return remoteInstance{}, fmt.Errorf("provider %s does not support get", p.name)
	}
}

func (p *Provider) waitForInstanceAndTCPPorts(ctx context.Context, instanceID string, ports []int, timeout time.Duration) (*cloud.Instance, error) {
	requiredPorts := uniquePositivePorts(ports)
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(catalogReadyProbeInterval)
	defer ticker.Stop()

	var lastErr error
	for {
		instance, err := p.GetInstance(waitCtx, instanceID)
		if err != nil {
			lastErr = err
		} else if instance != nil {
			status := strings.ToLower(strings.TrimSpace(instance.Status))
			if (status == "active" || status == "running") && strings.TrimSpace(instance.IPv4) != "" {
				pending := pendingTCPPorts(instance.IPv4, requiredPorts, catalogReadyDialTimeout)
				if len(pending) == 0 {
					return instance, nil
				}
				lastErr = fmt.Errorf("pending tcp ports on %s: %s", instance.IPv4, portsToCSV(pending))
			} else {
				lastErr = fmt.Errorf("instance not ready yet: status=%s ipv4=%s", status, strings.TrimSpace(instance.IPv4))
			}
		}

		select {
		case <-waitCtx.Done():
			if lastErr != nil {
				return nil, fmt.Errorf("timeout waiting for %s instance %s readiness: %w", p.name, instanceID, lastErr)
			}
			return nil, fmt.Errorf("timeout waiting for %s instance %s readiness", p.name, instanceID)
		case <-ticker.C:
		}
	}
}

func (p *Provider) instanceFromRemoteAndRecord(ri remoteInstance, rec cloud.InstanceRecord) cloud.Instance {
	inst := cloud.Instance{
		ID:        ri.ID,
		Provider:  p.name,
		Label:     firstNonEmpty(ri.Label, "node"),
		Status:    firstNonEmpty(ri.Status, "unknown"),
		Region:    ri.Region,
		Plan:      firstNonEmpty(ri.Plan, rec.Plan),
		IPv4:      firstNonEmpty(ri.IPv4, rec.IPv4),
		IPv6:      firstNonEmpty(ri.IPv6, rec.IPv6),
		CreatedAt: ri.CreatedAt,
	}
	if inst.CreatedAt.IsZero() {
		inst.CreatedAt = parseRFC3339(rec.CreatedAt)
	}

	inst.SSPort = rec.SSPort
	inst.SSPassword = rec.SSPassword
	inst.HysteriaPort = rec.HysteriaPort
	inst.HysteriaPassword = rec.HysteriaPassword
	inst.HysteriaServerName = rec.HysteriaServerName
	inst.HysteriaInsecure = rec.HysteriaInsecure
	inst.VLESSPort = rec.VLESSPort
	inst.VLESSUUID = rec.VLESSUUID
	inst.VLESSPublicKey = rec.VLESSPublicKey
	inst.VLESSShortID = rec.VLESSShortID
	inst.VLESSServerName = rec.VLESSServerName
	inst.TrojanPort = rec.TrojanPort
	inst.TrojanPassword = rec.TrojanPassword
	inst.TrojanServerName = rec.TrojanServerName
	inst.TrojanInsecure = rec.TrojanInsecure
	return inst
}
