// cloud-readonly-check performs the stable-release cloud credential smoke test.
//
// This command deliberately does not use CloudProvider.ListInstances: those
// application-facing methods may merge local records or attempt best-effort SSH
// credential recovery.  Every network request made here goes through a
// fail-closed transport that permits GET and rejects every other HTTP method.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"
)

const maxResponseBytes = 8 << 20

type opResult struct {
	OK         bool   `json:"ok"`
	Count      int    `json:"count"`
	DurationMS int64  `json:"durationMs"`
	Error      string `json:"error,omitempty"`
}

type providerReport struct {
	Provider      string   `json:"provider"`
	HasKey        bool     `json:"hasKey"`
	ValidateError string   `json:"validateError,omitempty"`
	RegionUsed    string   `json:"regionUsed,omitempty"`
	Regions       opResult `json:"regions"`
	Plans         opResult `json:"plans"`
	Availability  opResult `json:"availability"`
	Instances     opResult `json:"instances"`
	LiveAPIOK     bool     `json:"liveApiOk"`
}

type fullReport struct {
	GeneratedAt string           `json:"generatedAt"`
	Providers   []providerReport `json:"providers"`
	Summary     map[string]int   `json:"summary"`
}

type providerProbe struct {
	name    string
	baseURL string
	apiKey  string
	client  *http.Client
}

type readOnlyTransport struct {
	base http.RoundTripper
}

func (t readOnlyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method != http.MethodGet {
		return nil, fmt.Errorf("read-only cloud probe rejected HTTP method %q", req.Method)
	}
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(req)
}

func newReadOnlyClient(timeout time.Duration, transport http.RoundTripper) *http.Client {
	return &http.Client{
		Timeout:   timeout,
		Transport: readOnlyTransport{base: transport},
		CheckRedirect: func(req *http.Request, _ []*http.Request) error {
			if req.Method != http.MethodGet {
				return fmt.Errorf("read-only cloud probe rejected redirect method %q", req.Method)
			}
			return nil
		},
	}
}

func (p providerProbe) getJSON(ctx context.Context, path string, out any) error {
	base, err := url.Parse(p.baseURL)
	if err != nil {
		return fmt.Errorf("invalid %s API base URL: %w", p.name, err)
	}
	rel, err := url.Parse(path)
	if err != nil {
		return fmt.Errorf("invalid %s API path: %w", p.name, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base.ResolveReference(rel).String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+p.apiKey)
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%s API GET failed: %w", p.name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s API GET returned status %d", p.name, resp.StatusCode)
	}

	limited := io.LimitReader(resp.Body, maxResponseBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return fmt.Errorf("read %s API response: %w", p.name, err)
	}
	if len(data) > maxResponseBytes {
		return fmt.Errorf("%s API response exceeds %d bytes", p.name, maxResponseBytes)
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("decode %s API response: %w", p.name, err)
	}
	return nil
}

func runCountOp(timeout time.Duration, fn func(context.Context) (int, error)) opResult {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	count, err := fn(ctx)
	out := opResult{OK: err == nil, Count: count, DurationMS: time.Since(start).Milliseconds()}
	if err != nil {
		out.Error = trimErr(err)
	}
	return out
}

func trimErr(err error) string {
	if err == nil {
		return ""
	}
	msg := strings.TrimSpace(err.Error())
	if len(msg) <= 220 {
		return msg
	}
	return msg[:220] + "..."
}

type vultrRegionResponse struct {
	Regions []struct {
		ID string `json:"id"`
	} `json:"regions"`
}

type vultrPlanResponse struct {
	Plans []struct {
		ID        string   `json:"id"`
		Locations []string `json:"locations"`
	} `json:"plans"`
}

type vultrInstanceResponse struct {
	Instances []json.RawMessage `json:"instances"`
}

type digitalOceanRegionResponse struct {
	Regions []struct {
		Slug      string `json:"slug"`
		Available bool   `json:"available"`
	} `json:"regions"`
}

type digitalOceanSizeResponse struct {
	Sizes []struct {
		Slug      string   `json:"slug"`
		Available bool     `json:"available"`
		Regions   []string `json:"regions"`
	} `json:"sizes"`
}

type digitalOceanDropletResponse struct {
	Droplets []json.RawMessage `json:"droplets"`
}

func includes(values []string, wanted string) bool {
	return slices.Contains(values, wanted)
}

func (p providerProbe) run(timeout time.Duration) providerReport {
	rep := providerReport{Provider: p.name, HasKey: strings.TrimSpace(p.apiKey) != ""}
	if !rep.HasKey {
		rep.ValidateError = "missing API key"
		skipped := opResult{Error: "skipped: invalid config"}
		rep.Regions, rep.Plans, rep.Availability, rep.Instances = skipped, skipped, skipped, skipped
		return rep
	}

	var pickedRegion string
	var vultrPlans vultrPlanResponse
	var doSizes digitalOceanSizeResponse

	switch p.name {
	case "vultr":
		rep.Regions = runCountOp(timeout, func(ctx context.Context) (int, error) {
			var response vultrRegionResponse
			if err := p.getJSON(ctx, "/v2/regions?per_page=500", &response); err != nil {
				return 0, err
			}
			if len(response.Regions) > 0 {
				pickedRegion = strings.TrimSpace(response.Regions[0].ID)
			}
			return len(response.Regions), nil
		})
		rep.Plans = runCountOp(timeout, func(ctx context.Context) (int, error) {
			if err := p.getJSON(ctx, "/v2/plans?per_page=500", &vultrPlans); err != nil {
				return 0, err
			}
			return len(vultrPlans.Plans), nil
		})
		rep.Availability = runCountOp(timeout, func(_ context.Context) (int, error) {
			if pickedRegion == "" {
				return 0, errors.New("no region returned by Vultr")
			}
			count := 0
			for _, plan := range vultrPlans.Plans {
				if len(plan.Locations) == 0 || includes(plan.Locations, pickedRegion) {
					count++
				}
			}
			return count, nil
		})
		rep.Instances = runCountOp(timeout, func(ctx context.Context) (int, error) {
			var response vultrInstanceResponse
			if err := p.getJSON(ctx, "/v2/instances?per_page=500", &response); err != nil {
				return 0, err
			}
			return len(response.Instances), nil
		})

	case "digitalocean":
		rep.Regions = runCountOp(timeout, func(ctx context.Context) (int, error) {
			var response digitalOceanRegionResponse
			if err := p.getJSON(ctx, "/v2/regions?per_page=200", &response); err != nil {
				return 0, err
			}
			count := 0
			for _, region := range response.Regions {
				if region.Available {
					count++
					if pickedRegion == "" {
						pickedRegion = strings.TrimSpace(region.Slug)
					}
				}
			}
			return count, nil
		})
		rep.Plans = runCountOp(timeout, func(ctx context.Context) (int, error) {
			if err := p.getJSON(ctx, "/v2/sizes?per_page=200", &doSizes); err != nil {
				return 0, err
			}
			count := 0
			for _, size := range doSizes.Sizes {
				if size.Available {
					count++
				}
			}
			return count, nil
		})
		rep.Availability = runCountOp(timeout, func(_ context.Context) (int, error) {
			if pickedRegion == "" {
				return 0, errors.New("no available region returned by DigitalOcean")
			}
			count := 0
			for _, size := range doSizes.Sizes {
				if size.Available && includes(size.Regions, pickedRegion) {
					count++
				}
			}
			return count, nil
		})
		rep.Instances = runCountOp(timeout, func(ctx context.Context) (int, error) {
			var response digitalOceanDropletResponse
			if err := p.getJSON(ctx, "/v2/droplets?per_page=200", &response); err != nil {
				return 0, err
			}
			return len(response.Droplets), nil
		})
	}

	rep.RegionUsed = pickedRegion
	rep.LiveAPIOK = rep.Regions.OK && rep.Plans.OK && rep.Availability.OK && rep.Instances.OK
	return rep
}

func keyFromEnv(provider string) string {
	switch provider {
	case "vultr":
		return strings.TrimSpace(os.Getenv("VULTR_API_KEY"))
	case "digitalocean":
		return strings.TrimSpace(os.Getenv("DIGITALOCEAN_API_KEY"))
	default:
		return ""
	}
}

func main() {
	timeoutSec := flag.Int("timeout-sec", 45, "timeout seconds for each provider API operation")
	providersCSV := flag.String("providers", "vultr,digitalocean", "comma-separated providers to probe (vultr,digitalocean only)")
	flag.Parse()
	if *timeoutSec <= 0 {
		fmt.Fprintln(os.Stderr, "timeout-sec must be positive")
		os.Exit(2)
	}

	baseURLs := map[string]string{
		"vultr":        "https://api.vultr.com",
		"digitalocean": "https://api.digitalocean.com",
	}
	selected := make([]string, 0, 2)
	seen := make(map[string]bool)
	for _, raw := range strings.Split(*providersCSV, ",") {
		name := strings.ToLower(strings.TrimSpace(raw))
		if _, ok := baseURLs[name]; !ok || seen[name] {
			continue
		}
		seen[name] = true
		selected = append(selected, name)
	}
	if len(selected) == 0 {
		fmt.Fprintln(os.Stderr, "no valid read-only providers selected")
		os.Exit(2)
	}

	timeout := time.Duration(*timeoutSec) * time.Second
	client := newReadOnlyClient(timeout, nil)
	report := fullReport{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Providers:   make([]providerReport, 0, len(selected)),
		Summary: map[string]int{
			"total": 0, "has_key": 0, "live_api_ok": 0,
			"missing_key": 0, "auth_or_api_err": 0,
		},
	}
	for _, name := range selected {
		rep := (providerProbe{name: name, baseURL: baseURLs[name], apiKey: keyFromEnv(name), client: client}).run(timeout)
		report.Providers = append(report.Providers, rep)
		report.Summary["total"]++
		if rep.HasKey {
			report.Summary["has_key"]++
		} else {
			report.Summary["missing_key"]++
		}
		if rep.LiveAPIOK {
			report.Summary["live_api_ok"]++
		} else if rep.HasKey {
			report.Summary["auth_or_api_err"]++
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(report); err != nil {
		fmt.Fprintf(os.Stderr, "encode report failed: %v\n", err)
		os.Exit(1)
	}
}
