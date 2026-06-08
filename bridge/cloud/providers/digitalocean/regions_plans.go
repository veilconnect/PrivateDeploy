package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"privatedeploy/bridge/cloud"
)

// ListRegions returns available DigitalOcean regions.
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/regions", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Regions []struct {
			Slug      string   `json:"slug"`
			Name      string   `json:"name"`
			Available bool     `json:"available"`
			Features  []string `json:"features"`
		} `json:"regions"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	regions := make([]cloud.Region, 0)
	for _, r := range result.Regions {
		if !r.Available {
			continue
		}
		city, country := parseRegionName(r.Name)
		regions = append(regions, cloud.Region{
			ID:      r.Slug,
			City:    city,
			Country: country,
		})
	}

	return regions, nil
}

// ListPlans returns available DigitalOcean droplet sizes.
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/sizes", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var result struct {
		Sizes []struct {
			Slug         string   `json:"slug"`
			Memory       int      `json:"memory"`
			VCPUs        int      `json:"vcpus"`
			Disk         int      `json:"disk"`
			Transfer     float64  `json:"transfer"`
			PriceMonthly float64  `json:"price_monthly"`
			PriceHourly  float64  `json:"price_hourly"`
			Available    bool     `json:"available"`
			Regions      []string `json:"regions"`
			Description  string   `json:"description"`
		} `json:"sizes"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	plans := make([]cloud.Plan, 0)
	for _, s := range result.Sizes {
		if !s.Available {
			continue
		}
		if region != "" && !contains(s.Regions, region) {
			continue
		}

		plans = append(plans, cloud.Plan{
			ID:          s.Slug,
			Description: s.Description,
			RAM:         s.Memory,
			VCPUs:       s.VCPUs,
			Disk:        s.Disk,
			Bandwidth:   int(s.Transfer * 1024),
			MonthlyCost: s.PriceMonthly,
			HourlyCost:  s.PriceHourly,
			Type:        "standard",
			Locations:   s.Regions,
		})
	}

	return plans, nil
}

// ListAvailability returns available plan slugs for a region.
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	plans, err := p.ListPlans(ctx, region)
	if err != nil {
		return nil, err
	}

	availability := make([]string, 0, len(plans))
	for _, plan := range plans {
		availability = append(availability, plan.ID)
	}

	return availability, nil
}

// parseRegionName maps the DigitalOcean region "name" field into a bilingual
// city label and an ISO country code. Falls back to (name, "Unknown") for
// regions not in the explicit map.
func parseRegionName(name string) (city, country string) {
	regionMap := map[string]struct {
		City    string
		Country string
	}{
		"New York 1":       {"New York 1 (纽约1)", "US"},
		"New York 2":       {"New York 2 (纽约2)", "US"},
		"New York 3":       {"New York 3 (纽约3)", "US"},
		"San Francisco 1":  {"San Francisco 1 (旧金山1)", "US"},
		"San Francisco 2":  {"San Francisco 2 (旧金山2)", "US"},
		"San Francisco 3":  {"San Francisco 3 (旧金山3)", "US"},
		"Toronto 1":        {"Toronto 1 (多伦多1)", "CA"},
		"London 1":         {"London 1 (伦敦1)", "GB"},
		"Frankfurt 1":      {"Frankfurt 1 (法兰克福1)", "DE"},
		"Amsterdam 1":      {"Amsterdam 1 (阿姆斯特丹1)", "NL"},
		"Amsterdam 2":      {"Amsterdam 2 (阿姆斯特丹2)", "NL"},
		"Amsterdam 3":      {"Amsterdam 3 (阿姆斯特丹3)", "NL"},
		"Singapore 1":      {"Singapore 1 (新加坡1)", "SG"},
		"Bangalore 1":      {"Bangalore 1 (班加罗尔1)", "IN"},
		"Sydney 1":         {"Sydney 1 (悉尼1)", "AU"},
		"San Jose 1":       {"San Jose 1 (圣何塞1)", "US"},
		"Silicon Valley 1": {"Silicon Valley 1 (硅谷1)", "US"},
		"Atlanta 1":        {"Atlanta 1 (亚特兰大1)", "US"},
	}

	if region, ok := regionMap[name]; ok {
		return region.City, region.Country
	}

	return name, "Unknown"
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
