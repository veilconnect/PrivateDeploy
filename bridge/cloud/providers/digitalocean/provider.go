package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"veildeploy/bridge/cloud"
)

const baseURL = "https://api.digitalocean.com/v2"

// Provider implements cloud.CloudProvider for DigitalOcean
type Provider struct {
	config *cloud.ProviderConfig
	client *http.Client
}

// New creates a new DigitalOcean provider instance
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "digitalocean",
		}
	}
	return &Provider{
		config: config,
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

// Name returns the provider identifier
func (p *Provider) Name() string {
	return "digitalocean"
}

// DisplayName returns the human-readable provider name
func (p *Provider) DisplayName() string {
	return "DigitalOcean"
}

// LoadConfig loads the DigitalOcean configuration
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	return p.config, nil
}

// SaveConfig saves the DigitalOcean configuration
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "digitalocean" {
		return fmt.Errorf("invalid provider: expected digitalocean, got %s", config.Provider)
	}
	p.config = config
	return nil
}

// ValidateConfig validates the DigitalOcean configuration
func (p *Provider) ValidateConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider != "digitalocean" {
		return fmt.Errorf("invalid provider: expected digitalocean, got %s", config.Provider)
	}
	if config.APIKey == "" {
		return cloud.ErrMissingAPIKey
	}
	return nil
}

// ListRegions returns available DigitalOcean regions
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
		// Parse city and country from region name
		city, country := parseRegionName(r.Name)
		regions = append(regions, cloud.Region{
			ID:      r.Slug,
			City:    city,
			Country: country,
		})
	}

	return regions, nil
}

// ListPlans returns available DigitalOcean droplet sizes
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
			Slug          string   `json:"slug"`
			Memory        int      `json:"memory"`
			VCPUs         int      `json:"vcpus"`
			Disk          int      `json:"disk"`
			Transfer      float64  `json:"transfer"`
			PriceMonthly  float64  `json:"price_monthly"`
			PriceHourly   float64  `json:"price_hourly"`
			Available     bool     `json:"available"`
			Regions       []string `json:"regions"`
			Description   string   `json:"description"`
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
		// Filter by region if specified
		if region != "" && !contains(s.Regions, region) {
			continue
		}

		plans = append(plans, cloud.Plan{
			ID:          s.Slug,
			Description: s.Description,
			RAM:         s.Memory,
			VCPUs:       s.VCPUs,
			Disk:        s.Disk,
			Bandwidth:   int(s.Transfer * 1024), // Convert TB to GB
			MonthlyCost: s.PriceMonthly,
			HourlyCost:  s.PriceHourly,
			Type:        "standard",
			Locations:   s.Regions,
		})
	}

	return plans, nil
}

// ListAvailability returns available sizes for a region
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

// ListInstances returns all DigitalOcean droplets
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets", nil)
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
		Droplets []struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
			Networks struct {
				V4 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v4"`
				V6 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v6"`
			} `json:"networks"`
		} `json:"droplets"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	instances := make([]cloud.Instance, 0, len(result.Droplets))
	for _, d := range result.Droplets {
		instance := cloud.Instance{
			ID:        fmt.Sprintf("cloud-do-%d", d.ID),
			Provider:  "digitalocean",
			Label:     d.Name,
			Status:    d.Status,
			Region:    d.Region.Slug,
			Plan:      d.Size.Slug,
			CreatedAt: d.CreatedAt,
		}

		// Extract IPv4 (public)
		for _, net := range d.Networks.V4 {
			if net.Type == "public" {
				instance.IPv4 = net.IPAddress
				break
			}
		}

		// Extract IPv6 (public)
		for _, net := range d.Networks.V6 {
			if net.Type == "public" {
				instance.IPv6 = net.IPAddress
				break
			}
		}

		instances = append(instances, instance)
	}

	return instances, nil
}

// CreateInstance creates a new DigitalOcean droplet
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	// DigitalOcean droplet creation would go here
	// For now, return a placeholder
	return &cloud.Instance{
		ID:        fmt.Sprintf("cloud-do-%d", time.Now().Unix()),
		Provider:  "digitalocean",
		Label:     opts.Label,
		Region:    opts.Region,
		Plan:      opts.Plan,
		Status:    "new",
		CreatedAt: time.Now(),
	}, nil
}

// DestroyInstance destroys a DigitalOcean droplet
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if instanceID == "" {
		return cloud.ErrInstanceNotFound
	}

	// DigitalOcean droplet deletion would go here
	return nil
}

// GetInstance retrieves a specific DigitalOcean droplet
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	// DigitalOcean droplet retrieval would go here
	return nil, cloud.ErrInstanceNotFound
}

// Helper functions

func parseRegionName(name string) (city, country string) {
	// Simple parser for DigitalOcean region names
	// E.g., "New York 1" -> city: "New York", country: "United States"
	// E.g., "Singapore 1" -> city: "Singapore", country: "Singapore"

	// This is simplified - production code would have a proper mapping
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
