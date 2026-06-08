package catalog

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"privatedeploy/bridge/cloud"
	"strings"
)

func (p *Provider) listRegionsFromAPI(ctx context.Context) ([]cloud.Region, error) {
	switch p.name {
	case "hetzner":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/locations", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list locations failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Locations []struct {
				Name     string `json:"name"`
				City     string `json:"city"`
				Country  string `json:"country"`
				NetworkZ string `json:"network_zone"`
			} `json:"locations"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		regions := make([]cloud.Region, 0, len(payload.Locations))
		for _, loc := range payload.Locations {
			regions = append(regions, cloud.Region{ID: loc.Name, City: firstNonEmpty(loc.City, loc.Name), Country: firstNonEmpty(loc.Country, "Unknown"), Continent: zoneToContinent(loc.NetworkZ)})
		}
		return regions, nil
	case "linode":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/regions", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list regions failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Data []struct {
				ID      string `json:"id"`
				Country string `json:"country"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		regions := make([]cloud.Region, 0, len(payload.Data))
		for _, r := range payload.Data {
			regions = append(regions, cloud.Region{ID: r.ID, City: r.ID, Country: firstNonEmpty(r.Country, "Unknown"), Continent: continentFromCountry(r.Country)})
		}
		return regions, nil
	case "scaleway":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/instance/v1/zones", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list scaleway zones failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Zones []json.RawMessage `json:"zones"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}

		regions := make([]cloud.Region, 0, len(payload.Zones))
		seen := map[string]struct{}{}
		for _, rawZone := range payload.Zones {
			var id string
			if err := json.Unmarshal(rawZone, &id); err != nil || strings.TrimSpace(id) == "" {
				var obj struct {
					Name string `json:"name"`
				}
				if err2 := json.Unmarshal(rawZone, &obj); err2 == nil {
					id = obj.Name
				}
			}
			id = strings.TrimSpace(id)
			if id == "" {
				continue
			}
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			city, country := scalewayZoneLocation(id)
			regions = append(regions, cloud.Region{
				ID:        id,
				City:      firstNonEmpty(city, id),
				Country:   firstNonEmpty(country, "Unknown"),
				Continent: continentFromCountry(country),
			})
		}
		return regions, nil
	case "upcloud":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/zone", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list upcloud zones failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Zones struct {
				Zone []struct {
					ID          string `json:"id"`
					Description string `json:"description"`
					Public      string `json:"public"`
				} `json:"zone"`
			} `json:"zones"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		regions := make([]cloud.Region, 0, len(payload.Zones.Zone))
		for _, z := range payload.Zones.Zone {
			if strings.EqualFold(strings.TrimSpace(z.Public), "no") {
				continue
			}
			country := countryFromRegionID(z.ID)
			regions = append(regions, cloud.Region{
				ID:        z.ID,
				City:      firstNonEmpty(z.Description, z.ID),
				Country:   firstNonEmpty(country, "Unknown"),
				Continent: continentFromCountry(country),
			})
		}
		return regions, nil
	case "contabo":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/v1/data-centers", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list contabo data centers failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Data []struct {
				Name       string `json:"name"`
				RegionName string `json:"regionName"`
				RegionSlug string `json:"regionSlug"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		seen := map[string]struct{}{}
		regions := make([]cloud.Region, 0, len(payload.Data))
		for _, dc := range payload.Data {
			regionID := strings.TrimSpace(dc.RegionSlug)
			if regionID == "" {
				continue
			}
			if _, ok := seen[regionID]; ok {
				continue
			}
			seen[regionID] = struct{}{}
			country := countryFromContaboRegion(regionID)
			regions = append(regions, cloud.Region{
				ID:        regionID,
				City:      firstNonEmpty(dc.Name, dc.RegionName, regionID),
				Country:   firstNonEmpty(country, "Unknown"),
				Continent: continentFromCountry(country),
			})
		}
		return regions, nil
	case "oracle":
		return p.oracleListRegions(ctx)
	default:
		return nil, fmt.Errorf("provider %s does not support region api", p.name)
	}
}

func (p *Provider) listPlansFromAPI(ctx context.Context) ([]cloud.Plan, error) {
	switch p.name {
	case "hetzner":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/server_types", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list server types failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			ServerTypes []struct {
				Name   string  `json:"name"`
				Cores  int     `json:"cores"`
				Memory float64 `json:"memory"`
				Disk   int     `json:"disk"`
				Prices []struct {
					PriceHourly struct {
						Net string `json:"net"`
					} `json:"price_hourly"`
				} `json:"prices"`
			} `json:"server_types"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		plans := make([]cloud.Plan, 0, len(payload.ServerTypes))
		for _, t := range payload.ServerTypes {
			hourly := parseFloat(firstPriceNet(t.Prices))
			monthly := math.Round(hourly*730*100) / 100
			plans = append(plans, cloud.Plan{ID: t.Name, Description: "Hetzner server type", RAM: int(t.Memory * 1024), VCPUs: t.Cores, Disk: t.Disk, Bandwidth: 20000, HourlyCost: hourly, MonthlyCost: monthly})
		}
		return plans, nil
	case "linode":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/linode/types", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list linode types failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Data []struct {
				ID     string `json:"id"`
				Label  string `json:"label"`
				Memory int    `json:"memory"`
				VCPUs  int    `json:"vcpus"`
				Disk   int    `json:"disk"`
				Price  struct {
					Monthly float64 `json:"monthly"`
					Hourly  float64 `json:"hourly"`
				} `json:"price"`
				NetworkOut int `json:"network_out"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		plans := make([]cloud.Plan, 0, len(payload.Data))
		for _, t := range payload.Data {
			plans = append(plans, cloud.Plan{ID: t.ID, Description: t.Label, RAM: t.Memory, VCPUs: t.VCPUs, Disk: t.Disk, Bandwidth: t.NetworkOut, MonthlyCost: t.Price.Monthly, HourlyCost: t.Price.Hourly})
		}
		return plans, nil
	case "upcloud":
		status, body, err := p.apiRequest(ctx, http.MethodGet, "/server/plan", nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("list upcloud plans failed: status=%d body=%s", status, strings.TrimSpace(string(body)))
		}
		var payload struct {
			Plans struct {
				Plan []struct {
					Name             string  `json:"name"`
					CoreNumber       int     `json:"core_number"`
					MemoryAmount     int     `json:"memory_amount"`
					StorageSize      int     `json:"storage_size"`
					PublicTrafficOut int     `json:"public_traffic_out"`
					Price            float64 `json:"price"`
				} `json:"plan"`
			} `json:"plans"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		plans := make([]cloud.Plan, 0, len(payload.Plans.Plan))
		for _, t := range payload.Plans.Plan {
			if strings.TrimSpace(t.Name) == "" {
				continue
			}
			plans = append(plans, cloud.Plan{
				ID:          t.Name,
				Description: "UpCloud server plan",
				RAM:         t.MemoryAmount,
				VCPUs:       t.CoreNumber,
				Disk:        t.StorageSize,
				Bandwidth:   t.PublicTrafficOut,
				MonthlyCost: t.Price,
			})
		}
		return plans, nil
	case "contabo":
		return append([]cloud.Plan(nil), p.plans...), nil
	case "oracle":
		return p.oracleListPlans(ctx)
	default:
		return nil, fmt.Errorf("provider %s does not support plans api", p.name)
	}
}
