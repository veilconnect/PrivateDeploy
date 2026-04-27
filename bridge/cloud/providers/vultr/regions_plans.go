package vultr

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

// ListRegions returns available Vultr regions.
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/regions", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Regions []vultrRegion `json:"regions"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	regions := make([]cloud.Region, 0, len(payload.Regions))
	for _, region := range payload.Regions {
		regions = append(regions, cloud.Region{
			ID:        region.ID,
			City:      region.City,
			Country:   region.Country,
			Continent: region.Continent,
		})
	}

	sort.Slice(regions, func(i, j int) bool {
		if regions[i].Country == regions[j].Country {
			return regions[i].City < regions[j].City
		}
		return regions[i].Country < regions[j].Country
	})

	return regions, nil
}

// ListPlans returns available Vultr plans for a region.
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/plans", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	plans := make([]cloud.Plan, 0, len(payload.Plans))
	for _, plan := range payload.Plans {
		if region != "" && len(plan.Locations) > 0 {
			found := false
			for _, loc := range plan.Locations {
				if loc == region {
					found = true
					break
				}
			}
			if !found {
				continue
			}
		}

		plans = append(plans, cloud.Plan{
			ID:          plan.ID,
			Description: plan.Description,
			RAM:         plan.MemoryMB,
			VCPUs:       plan.VCPUs,
			Disk:        plan.DiskGB,
			Bandwidth:   plan.BandwidthGB,
			MonthlyCost: plan.MonthlyCost,
			HourlyCost:  plan.HourlyCost,
			Type:        plan.Type,
			Locations:   plan.Locations,
		})
	}

	sort.Slice(plans, func(i, j int) bool {
		if plans[i].RAM == plans[j].RAM {
			return plans[i].ID < plans[j].ID
		}
		return plans[i].RAM < plans[j].RAM
	})

	return plans, nil
}

// ListAvailability returns available plan IDs for a region.
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	if strings.TrimSpace(region) == "" {
		return nil, fmt.Errorf("region is required")
	}

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

func (p *Provider) getPlanRAM(ctx context.Context, planID string) (int, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/plans", nil)
	if err != nil {
		return 0, err
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return 0, err
	}

	for _, plan := range payload.Plans {
		if plan.ID == planID {
			return plan.MemoryMB, nil
		}
	}
	return 0, fmt.Errorf("plan %s not found", planID)
}

func (p *Provider) preferredOSIDs(ctx context.Context) ([]int, error) {
	osList, err := p.listOperatingSystems(ctx)
	if err != nil {
		return nil, err
	}

	var result []int

	addMatches := func(predicate func(vultrOS) bool) {
		for _, os := range osList {
			if predicate(os) {
				appendUniqueInt(&result, os.ID)
			}
		}
	}

	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "11")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "20.04")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "12")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "22.04")
	})
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "24.04")
	})
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian")
	})
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu")
	})
	for _, os := range osList {
		appendUniqueInt(&result, os.ID)
	}

	return result, nil
}

func (p *Provider) listOperatingSystems(ctx context.Context) ([]vultrOS, error) {
	osCacheMu.Lock()
	defer osCacheMu.Unlock()

	if len(osCache) > 0 && time.Since(osCacheTime) < time.Hour {
		cached := make([]vultrOS, len(osCache))
		copy(cached, osCache)
		return cached, nil
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/os", nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		OperatingSystems []vultrOS `json:"os"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	osCache = payload.OperatingSystems
	osCacheTime = time.Now()

	cached := make([]vultrOS, len(osCache))
	copy(cached, osCache)
	return cached, nil
}

func appendUniqueInt(list *[]int, candidate int) {
	for _, existing := range *list {
		if existing == candidate {
			return
		}
	}
	*list = append(*list, candidate)
}
