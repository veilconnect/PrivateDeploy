package catalog

import (
	"bytes"
	"context"
	cryptorand "crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

const (
	hetznerAPIBaseURL           = "https://api.hetzner.cloud/v1"
	linodeAPIBaseURL            = "https://api.linode.com/v4"
	scalewayAPIBaseURL          = "https://api.scaleway.com"
	upcloudAPIBaseURL           = "https://api.upcloud.com/1.3"
	contaboAPIBaseURL           = "https://api.contabo.com"
	contaboAuthTokenURL         = "https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token"
	catalogDefaultHTTPTimeout   = 45 * time.Second
	catalogDefaultReadyTimeout  = 7 * time.Minute
	catalogReadyProbeInterval   = 5 * time.Second
	catalogReadyDialTimeout     = 2 * time.Second
	catalogDefaultOracleTimeout = 90 * time.Second
	catalogDefaultCreateImageHZ = "ubuntu-22.04"
	catalogDefaultCreateImageLI = "linode/ubuntu22.04"
)

var catalogNodesMu sync.Mutex

// remoteInstance is provider-agnostic shape for API lifecycle operations.
type remoteInstance struct {
	RawID     string
	ID        string
	Label     string
	Status    string
	Region    string
	Plan      string
	IPv4      string
	IPv6      string
	CreatedAt time.Time
}

type contaboCredentials struct {
	ClientID     string
	ClientSecret string
	Username     string
	Password     string
}

// Provider offers catalog support for multiple providers and lifecycle support
// for the providers implemented in this package.
type Provider struct {
	name        string
	displayName string
	configPath  string
	nodesPath   string
	regions     []cloud.Region
	plans       []cloud.Plan
	config      *cloud.ProviderConfig
	client      *http.Client
	tokenMu     sync.Mutex
	token       string
	tokenExpiry time.Time
}

// NewHetzner creates the Hetzner Cloud provider.
func NewHetzner(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("hetzner", "Hetzner", config, []cloud.Region{
		{ID: "nbg1", City: "Nuremberg", Country: "Germany", Continent: "Europe"},
		{ID: "fsn1", City: "Falkenstein", Country: "Germany", Continent: "Europe"},
		{ID: "hel1", City: "Helsinki", Country: "Finland", Continent: "Europe"},
		{ID: "ash", City: "Ashburn", Country: "United States", Continent: "North America"},
		{ID: "hil", City: "Hillsboro", Country: "United States", Continent: "North America"},
		{ID: "sin", City: "Singapore", Country: "Singapore", Continent: "Asia"},
	}, []cloud.Plan{
		{ID: "cx22", Description: "Shared vCPU", RAM: 4096, VCPUs: 2, Disk: 40, Bandwidth: 20000, MonthlyCost: 5.0, Type: "shared"},
		{ID: "cx32", Description: "Shared vCPU", RAM: 8192, VCPUs: 4, Disk: 80, Bandwidth: 20000, MonthlyCost: 10.0, Type: "shared"},
		{ID: "cax11", Description: "Arm64", RAM: 2048, VCPUs: 2, Disk: 40, Bandwidth: 20000, MonthlyCost: 4.0, Type: "arm"},
	})
}

// NewLinode creates the Linode provider.
func NewLinode(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("linode", "Linode", config, []cloud.Region{
		{ID: "us-ord", City: "Chicago", Country: "United States", Continent: "North America"},
		{ID: "us-sea", City: "Seattle", Country: "United States", Continent: "North America"},
		{ID: "us-east", City: "Newark", Country: "United States", Continent: "North America"},
		{ID: "eu-west", City: "London", Country: "United Kingdom", Continent: "Europe"},
		{ID: "eu-central", City: "Frankfurt", Country: "Germany", Continent: "Europe"},
		{ID: "ap-south", City: "Singapore", Country: "Singapore", Continent: "Asia"},
		{ID: "ap-northeast", City: "Tokyo", Country: "Japan", Continent: "Asia"},
	}, []cloud.Plan{
		{ID: "g6-nanode-1", Description: "Shared CPU", RAM: 1024, VCPUs: 1, Disk: 25, Bandwidth: 1000, MonthlyCost: 5.0, Type: "shared"},
		{ID: "g6-standard-1", Description: "Shared CPU", RAM: 2048, VCPUs: 1, Disk: 50, Bandwidth: 2000, MonthlyCost: 10.0, Type: "shared"},
		{ID: "g6-standard-2", Description: "Shared CPU", RAM: 4096, VCPUs: 2, Disk: 80, Bandwidth: 4000, MonthlyCost: 20.0, Type: "shared"},
	})
}

// NewScaleway creates the Scaleway provider.
func NewScaleway(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("scaleway", "Scaleway", config, []cloud.Region{
		{ID: "fr-par-1", City: "Paris", Country: "France", Continent: "Europe"},
		{ID: "nl-ams-1", City: "Amsterdam", Country: "Netherlands", Continent: "Europe"},
		{ID: "pl-waw-1", City: "Warsaw", Country: "Poland", Continent: "Europe"},
	}, []cloud.Plan{
		{ID: "DEV1-S", Description: "Development", RAM: 2048, VCPUs: 2, Disk: 20, Bandwidth: 1000, MonthlyCost: 4.0, Type: "dev"},
		{ID: "PLAY2-NANO", Description: "General Purpose", RAM: 2048, VCPUs: 2, Disk: 20, Bandwidth: 1000, MonthlyCost: 6.0, Type: "play"},
		{ID: "PLAY2-MICRO", Description: "General Purpose", RAM: 4096, VCPUs: 2, Disk: 40, Bandwidth: 1000, MonthlyCost: 12.0, Type: "play"},
	})
}

// NewUpCloud creates the UpCloud provider.
func NewUpCloud(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("upcloud", "UpCloud", config, []cloud.Region{
		{ID: "us-chi1", City: "Chicago", Country: "United States", Continent: "North America"},
		{ID: "us-nyc1", City: "New York", Country: "United States", Continent: "North America"},
		{ID: "de-fra1", City: "Frankfurt", Country: "Germany", Continent: "Europe"},
		{ID: "uk-lon1", City: "London", Country: "United Kingdom", Continent: "Europe"},
		{ID: "sg-sin1", City: "Singapore", Country: "Singapore", Continent: "Asia"},
	}, []cloud.Plan{
		{ID: "1xCPU-1GB", Description: "Developer", RAM: 1024, VCPUs: 1, Disk: 25, Bandwidth: 1000, MonthlyCost: 3.5, Type: "dev"},
		{ID: "1xCPU-2GB", Description: "Developer", RAM: 2048, VCPUs: 1, Disk: 50, Bandwidth: 2000, MonthlyCost: 7.0, Type: "dev"},
		{ID: "2xCPU-4GB", Description: "General", RAM: 4096, VCPUs: 2, Disk: 80, Bandwidth: 4000, MonthlyCost: 14.0, Type: "general"},
	})
}

// NewContabo creates the Contabo provider.
func NewContabo(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("contabo", "Contabo", config, []cloud.Region{
		{ID: "EU", City: "Nuremberg", Country: "Germany", Continent: "Europe"},
		{ID: "US-central", City: "St. Louis", Country: "United States", Continent: "North America"},
		{ID: "US-east", City: "New York", Country: "United States", Continent: "North America"},
		{ID: "US-west", City: "Seattle", Country: "United States", Continent: "North America"},
		{ID: "SIN", City: "Singapore", Country: "Singapore", Continent: "Asia"},
		{ID: "UK", City: "Portsmouth", Country: "United Kingdom", Continent: "Europe"},
		{ID: "AUS", City: "Sydney", Country: "Australia", Continent: "Oceania"},
		{ID: "JPN", City: "Tokyo", Country: "Japan", Continent: "Asia"},
		{ID: "IND", City: "Mumbai", Country: "India", Continent: "Asia"},
	}, []cloud.Plan{
		{ID: "V91", Description: "VPS S SSD", RAM: 4096, VCPUs: 4, Disk: 50, Bandwidth: 32000, MonthlyCost: 4.5, Type: "vps"},
		{ID: "V92", Description: "VPS M SSD", RAM: 8192, VCPUs: 4, Disk: 100, Bandwidth: 32000, MonthlyCost: 8.5, Type: "vps"},
		{ID: "V93", Description: "VPS L SSD", RAM: 16384, VCPUs: 6, Disk: 200, Bandwidth: 32000, MonthlyCost: 14.5, Type: "vps"},
	})
}

// NewOracle creates the Oracle Cloud provider.
func NewOracle(config *cloud.ProviderConfig) *Provider {
	return newCatalogProvider("oracle", "Oracle Cloud", config, []cloud.Region{
		{ID: "us-ashburn-1", City: "Ashburn", Country: "United States", Continent: "North America"},
		{ID: "us-phoenix-1", City: "Phoenix", Country: "United States", Continent: "North America"},
		{ID: "eu-frankfurt-1", City: "Frankfurt", Country: "Germany", Continent: "Europe"},
		{ID: "uk-london-1", City: "London", Country: "United Kingdom", Continent: "Europe"},
		{ID: "ap-singapore-1", City: "Singapore", Country: "Singapore", Continent: "Asia"},
		{ID: "ap-tokyo-1", City: "Tokyo", Country: "Japan", Continent: "Asia"},
	}, []cloud.Plan{
		{ID: "VM.Standard.E2.1.Micro", Description: "Always Free", RAM: 1024, VCPUs: 1, Disk: 50, Bandwidth: 10000, MonthlyCost: 0, Type: "always-free"},
		{ID: "VM.Standard.A1.Flex", Description: "Arm Flex", RAM: 6144, VCPUs: 1, Disk: 50, Bandwidth: 10000, MonthlyCost: 0, Type: "always-free"},
		{ID: "VM.Standard3.Flex", Description: "General Purpose", RAM: 2048, VCPUs: 1, Disk: 50, Bandwidth: 10000, MonthlyCost: 0, Type: "flex"},
	})
}

func newCatalogProvider(name, displayName string, config *cloud.ProviderConfig, regions []cloud.Region, plans []cloud.Plan) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{Provider: name}
	}
	if config.Provider == "" {
		config.Provider = name
	}

	basePath := os.Getenv("PRIVATEDEPLOY_BASE_PATH")
	if basePath == "" {
		basePath, _ = os.Getwd()
	}

	return &Provider{
		name:        name,
		displayName: displayName,
		configPath:  filepath.Join(basePath, "data", "cloud", name+"-config.json"),
		nodesPath:   filepath.Join(basePath, "data", "cloud", name+"-nodes.json"),
		regions:     append([]cloud.Region(nil), regions...),
		plans:       append([]cloud.Plan(nil), plans...),
		config:      config,
		client:      &http.Client{Timeout: catalogDefaultHTTPTimeout},
	}
}

func (p *Provider) Name() string { return p.name }

func (p *Provider) DisplayName() string { return p.displayName }

func (p *Provider) supportsLifecycle() bool {
	switch p.name {
	case "hetzner", "linode", "scaleway", "upcloud", "contabo", "oracle":
		return true
	default:
		return false
	}
}

func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	if p.supportsLifecycle() {
		if regions, err := p.listRegionsFromAPI(ctx); err == nil && len(regions) > 0 {
			return regions, nil
		}
	}
	return append([]cloud.Region(nil), p.regions...), nil
}

func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	plans := append([]cloud.Plan(nil), p.plans...)
	if p.supportsLifecycle() {
		if apiPlans, err := p.listPlansFromAPI(ctx); err == nil && len(apiPlans) > 0 {
			plans = apiPlans
		}
	}

	if region == "" {
		return plans, nil
	}
	filtered := make([]cloud.Plan, 0, len(plans))
	for _, plan := range plans {
		if len(plan.Locations) == 0 || slices.Contains(plan.Locations, region) {
			filtered = append(filtered, plan)
		}
	}
	return filtered, nil
}

func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	plans, err := p.ListPlans(ctx, region)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(plans))
	for _, plan := range plans {
		ids = append(ids, plan.ID)
	}
	return ids, nil
}

func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	if !p.supportsLifecycle() {
		return []cloud.Instance{}, nil
	}

	remoteInstances, err := p.listRemoteInstances(ctx)
	if err != nil {
		return nil, err
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	dirty := false
	instances := make([]cloud.Instance, 0, len(remoteInstances))
	for _, ri := range remoteInstances {
		rec := records[ri.ID]
		updated := false

		if ri.IPv4 != "" && rec.IPv4 != ri.IPv4 {
			rec.IPv4 = ri.IPv4
			updated = true
		}
		if ri.IPv6 != "" && rec.IPv6 != ri.IPv6 {
			rec.IPv6 = ri.IPv6
			updated = true
		}
		if ri.Plan != "" && rec.Plan != ri.Plan {
			rec.Plan = ri.Plan
			updated = true
		}
		if !ri.CreatedAt.IsZero() {
			created := ri.CreatedAt.Format(time.RFC3339)
			if rec.CreatedAt != created {
				rec.CreatedAt = created
				updated = true
			}
		}
		if ensureManagedTLSDefaults(&rec) {
			updated = true
		}
		if updated {
			records[ri.ID] = rec
			dirty = true
		}

		inst := p.instanceFromRemoteAndRecord(ri, rec)
		instances = append(instances, inst)
	}

	if dirty {
		_ = p.saveNodeRecords(records)
	}
	return instances, nil
}

func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if !p.supportsLifecycle() {
		return nil, fmt.Errorf("provider %s is configured, but automatic instance provisioning is not implemented yet; use vultr/digitalocean/ssh for deployment", p.name)
	}
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return nil, err
	}

	region := strings.TrimSpace(opts.Region)
	if region == "" {
		region = strings.TrimSpace(cfg.DefaultRegion)
	}
	if region == "" && len(p.regions) > 0 {
		region = p.regions[0].ID
	}

	plan := strings.TrimSpace(opts.Plan)
	if plan == "" {
		plan = strings.TrimSpace(cfg.DefaultPlan)
	}
	if plan == "" && len(p.plans) > 0 {
		plan = p.plans[0].ID
	}

	label := strings.TrimSpace(opts.Label)
	if label == "" {
		label = fmt.Sprintf("pd-%s-%d", p.name, time.Now().Unix())
	}

	extra := mergeExtra(cfg.Extra, opts.Extra)
	tuning := deploy.ResolveDeploymentTuning(extra)
	ports := deploy.AllocatePorts(tuning.PortProfile)

	ssPort := ports.SSPort
	ssPassword := deploy.GenerateRandomPassword(16)
	hysteriaPort := ports.HysteriaPort
	hysteriaPassword := deploy.GenerateRandomPassword(22)
	vlessPort := ports.VLESSPort
	vlessUUID := deploy.GenerateUUID()
	trojanPort := ports.TrojanPort
	trojanPassword := deploy.GenerateRandomPassword(22)

	realityPrivateKey, realityPublicKey, err := deploy.GenerateRealityKeyPair()
	if err != nil {
		realityPrivateKey = ""
		realityPublicKey = ""
	}
	realityShortID := fmt.Sprintf("%016x", rand.Int63())

	userData := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort:           ssPort,
		SSPassword:       ssPassword,
		HysteriaPort:     hysteriaPort,
		HysteriaPassword: hysteriaPassword,
		HysteriaServer:   tuning.HysteriaServerName,
		HysteriaMasqURL:  tuning.HysteriaMasqueradeURL,
		VLESSPort:        vlessPort,
		VLESSUUID:        vlessUUID,
		VLESSPrivateKey:  realityPrivateKey,
		VLESSPublicKey:   realityPublicKey,
		VLESSShortID:     realityShortID,
		VLESSServer:      tuning.VLESSServerName,
		TrojanPort:       trojanPort,
		TrojanPassword:   trojanPassword,
		TrojanServer:     tuning.TrojanServerName,
		SingBoxVersion:   tuning.SingBoxVersion,
		SingBoxFallback:  tuning.SingBoxFallbackVersion,
	})
	if strings.TrimSpace(userData) == "" {
		return nil, fmt.Errorf("failed to generate deployment script")
	}

	remote, err := p.createRemoteInstance(ctx, label, region, plan, userData)
	if err != nil {
		return nil, err
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	records[remote.ID] = cloud.InstanceRecord{
		Plan:               remote.Plan,
		IPv4:               remote.IPv4,
		IPv6:               remote.IPv6,
		CreatedAt:          remote.CreatedAt.Format(time.RFC3339),
		SSPort:             ssPort,
		SSPassword:         ssPassword,
		HysteriaPort:       hysteriaPort,
		HysteriaPassword:   hysteriaPassword,
		HysteriaServerName: tuning.HysteriaServerName,
		HysteriaInsecure:   deploy.BoolPtr(tuning.HysteriaInsecure),
		VLESSPort:          vlessPort,
		VLESSUUID:          vlessUUID,
		VLESSPublicKey:     realityPublicKey,
		VLESSShortID:       realityShortID,
		VLESSServerName:    tuning.VLESSServerName,
		TrojanPort:         trojanPort,
		TrojanPassword:     trojanPassword,
		TrojanServerName:   tuning.TrojanServerName,
		TrojanInsecure:     deploy.BoolPtr(tuning.TrojanInsecure),
	}
	if err := p.saveNodeRecords(records); err != nil {
		return nil, err
	}

	instance := p.instanceFromRemoteAndRecord(remote, records[remote.ID])
	readyPorts := []int{ssPort, vlessPort, trojanPort}
	if ready, waitErr := p.waitForInstanceAndTCPPorts(ctx, remote.ID, readyPorts, catalogDefaultReadyTimeout); waitErr == nil && ready != nil {
		instance = *ready
	}
	return &instance, nil
}

func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if !p.supportsLifecycle() {
		return fmt.Errorf("provider %s does not support instance lifecycle operations yet", p.name)
	}

	remoteID := p.stripCloudPrefix(instanceID)
	if remoteID == "" {
		return cloud.ErrInstanceNotFound
	}

	if p.name == "oracle" {
		if err := p.oracleDestroyInstance(ctx, remoteID); err != nil {
			return err
		}
		_ = p.deleteNodeRecord(instanceID)
		return nil
	}

	method := http.MethodDelete
	path := p.remotePathForID(remoteID)
	var payload any
	if p.name == "contabo" {
		method = http.MethodPost
		path = path + "/cancel"
		payload = map[string]any{}
	}

	status, body, err := p.apiRequest(ctx, method, path, payload)
	if err != nil {
		return err
	}
	if status != http.StatusNoContent && status != http.StatusAccepted && status != http.StatusOK && status != http.StatusNotFound {
		return fmt.Errorf("failed to destroy instance %s: status=%d body=%s", instanceID, status, strings.TrimSpace(string(body)))
	}
	_ = p.deleteNodeRecord(instanceID)
	return nil
}

func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if !p.supportsLifecycle() {
		return nil, fmt.Errorf("provider %s does not support querying remote instances yet", p.name)
	}

	remoteID := p.stripCloudPrefix(instanceID)
	if remoteID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	remote, err := p.getRemoteInstance(ctx, remoteID)
	if err != nil {
		return nil, err
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	rec := records[remote.ID]
	updated := false
	if remote.IPv4 != "" && rec.IPv4 != remote.IPv4 {
		rec.IPv4 = remote.IPv4
		updated = true
	}
	if remote.IPv6 != "" && rec.IPv6 != remote.IPv6 {
		rec.IPv6 = remote.IPv6
		updated = true
	}
	if remote.Plan != "" && rec.Plan != remote.Plan {
		rec.Plan = remote.Plan
		updated = true
	}
	if !remote.CreatedAt.IsZero() {
		created := remote.CreatedAt.Format(time.RFC3339)
		if rec.CreatedAt != created {
			rec.CreatedAt = created
			updated = true
		}
	}
	if ensureManagedTLSDefaults(&rec) {
		updated = true
	}
	if updated {
		records[remote.ID] = rec
		_ = p.saveNodeRecords(records)
	}

	instance := p.instanceFromRemoteAndRecord(remote, rec)
	return &instance, nil
}

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

func (p *Provider) apiRequest(ctx context.Context, method, path string, payload any) (int, []byte, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return 0, nil, err
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return 0, nil, cloud.ErrMissingAPIKey
	}

	base := p.baseURL()
	if strings.TrimSpace(base) == "" {
		return 0, nil, fmt.Errorf("provider %s has no api base url", p.name)
	}
	url := base + path
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, err
		}
		body = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	switch p.name {
	case "hetzner", "linode":
		req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	case "scaleway":
		req.Header.Set("X-Auth-Token", cfg.APIKey)
	case "upcloud":
		username, password, err := upcloudCredentials(cfg)
		if err != nil {
			return 0, nil, err
		}
		req.SetBasicAuth(username, password)
	case "contabo":
		token, err := p.contaboAccessToken(ctx, cfg)
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("x-request-id", pseudoUUIDv4())
		req.Header.Set("x-trace-id", pseudoUUIDv4())
	default:
		req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	}

	resp, err := p.client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody, nil
}

func (p *Provider) contaboCredentials(cfg *cloud.ProviderConfig) (contaboCredentials, error) {
	if cfg == nil {
		return contaboCredentials{}, cloud.ErrInvalidConfig
	}
	extra := cfg.Extra
	obj := parseAPIKeyObject(cfg.APIKey)

	creds := contaboCredentials{
		ClientID: firstNonEmpty(
			strings.TrimSpace(extra["clientId"]),
			strings.TrimSpace(extra["client_id"]),
			strings.TrimSpace(extra["oauthClientId"]),
			lookupMapValue(obj, "clientid", "client_id", "oauthclientid"),
		),
		ClientSecret: firstNonEmpty(
			strings.TrimSpace(extra["clientSecret"]),
			strings.TrimSpace(extra["client_secret"]),
			strings.TrimSpace(extra["oauthClientSecret"]),
			lookupMapValue(obj, "clientsecret", "client_secret", "oauthclientsecret"),
		),
		Username: firstNonEmpty(
			strings.TrimSpace(extra["username"]),
			strings.TrimSpace(extra["user"]),
			strings.TrimSpace(extra["apiUser"]),
			strings.TrimSpace(extra["api_user"]),
			lookupMapValue(obj, "username", "user", "apiuser", "api_user"),
		),
		Password: firstNonEmpty(
			strings.TrimSpace(extra["password"]),
			strings.TrimSpace(extra["apiPassword"]),
			strings.TrimSpace(extra["api_password"]),
			lookupMapValue(obj, "password", "apipassword", "api_password"),
		),
	}

	if creds.ClientID == "" || creds.ClientSecret == "" || creds.Username == "" || creds.Password == "" {
		parts := strings.SplitN(strings.TrimSpace(cfg.APIKey), "|", 4)
		if len(parts) == 4 {
			if creds.ClientID == "" {
				creds.ClientID = strings.TrimSpace(parts[0])
			}
			if creds.ClientSecret == "" {
				creds.ClientSecret = strings.TrimSpace(parts[1])
			}
			if creds.Username == "" {
				creds.Username = strings.TrimSpace(parts[2])
			}
			if creds.Password == "" {
				creds.Password = strings.TrimSpace(parts[3])
			}
		}
	}

	if creds.ClientID == "" || creds.ClientSecret == "" || creds.Username == "" || creds.Password == "" {
		return contaboCredentials{}, fmt.Errorf("contabo credentials are incomplete: use API key format 'client_id|client_secret|username|password' or provide values in extra")
	}
	return creds, nil
}

func (p *Provider) contaboAccessToken(ctx context.Context, cfg *cloud.ProviderConfig) (string, error) {
	p.tokenMu.Lock()
	if strings.TrimSpace(p.token) != "" && time.Now().Before(p.tokenExpiry) {
		token := p.token
		p.tokenMu.Unlock()
		return token, nil
	}
	p.tokenMu.Unlock()

	creds, err := p.contaboCredentials(cfg)
	if err != nil {
		return "", err
	}

	form := url.Values{}
	form.Set("client_id", creds.ClientID)
	form.Set("client_secret", creds.ClientSecret)
	form.Set("username", creds.Username)
	form.Set("password", creds.Password)
	form.Set("grant_type", "password")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, contaboAuthTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("contabo token request failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}
	token := strings.TrimSpace(payload.AccessToken)
	if token == "" {
		return "", fmt.Errorf("contabo token response missing access_token")
	}
	exp := time.Now().Add(30 * time.Minute)
	if payload.ExpiresIn > 120 {
		exp = time.Now().Add(time.Duration(payload.ExpiresIn-60) * time.Second)
	}

	p.tokenMu.Lock()
	p.token = token
	p.tokenExpiry = exp
	p.tokenMu.Unlock()

	return token, nil
}

func pseudoUUIDv4() string {
	buf := make([]byte, 16)
	if _, err := cryptorand.Read(buf); err != nil {
		now := time.Now().UnixNano()
		return fmt.Sprintf("pd-%x", now)
	}
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	hexRaw := hex.EncodeToString(buf)
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexRaw[0:8], hexRaw[8:12], hexRaw[12:16], hexRaw[16:20], hexRaw[20:32])
}

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

func (p *Provider) oracleListRegions(ctx context.Context) ([]cloud.Region, error) {
	out, err := p.oracleCLI(ctx, "iam", "region", "list", "--all")
	if err != nil {
		return nil, err
	}
	var payload struct {
		Data []struct {
			Name string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, err
	}
	regions := make([]cloud.Region, 0, len(payload.Data))
	for _, item := range payload.Data {
		regionID := strings.TrimSpace(item.Name)
		if regionID == "" {
			continue
		}
		city, country := oracleRegionLocation(regionID)
		regions = append(regions, cloud.Region{
			ID:        regionID,
			City:      firstNonEmpty(city, regionID),
			Country:   firstNonEmpty(country, "Unknown"),
			Continent: continentFromCountry(country),
		})
	}
	if len(regions) == 0 {
		return nil, fmt.Errorf("oracle returned no regions")
	}
	return regions, nil
}

func (p *Provider) oracleListPlans(_ context.Context) ([]cloud.Plan, error) {
	return append([]cloud.Plan(nil), p.plans...), nil
}

func (p *Provider) oracleExtra(cfg *cloud.ProviderConfig, keys ...string) string {
	if cfg == nil {
		return ""
	}
	obj := parseAPIKeyObject(cfg.APIKey)
	for _, key := range keys {
		if v := strings.TrimSpace(cfg.Extra[key]); v != "" {
			return v
		}
		if v := lookupMapValue(obj, key); v != "" {
			return v
		}
	}
	return ""
}

func (p *Provider) oracleCLI(ctx context.Context, args ...string) ([]byte, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return nil, err
	}

	fullArgs := append([]string(nil), args...)
	if !slices.Contains(fullArgs, "--output") {
		fullArgs = append(fullArgs, "--output", "json")
	}
	if !slices.Contains(fullArgs, "--profile") {
		profile := p.oracleExtra(cfg, "profile", "oracle_profile")
		if profile == "" {
			raw := strings.TrimSpace(cfg.APIKey)
			if raw != "" && !strings.HasPrefix(raw, "{") {
				profile = raw
			}
		}
		if profile == "" {
			profile = "DEFAULT"
		}
		fullArgs = append(fullArgs, "--profile", profile)
	}

	runCtx := ctx
	var cancel context.CancelFunc
	if _, ok := ctx.Deadline(); !ok {
		runCtx, cancel = context.WithTimeout(ctx, catalogDefaultOracleTimeout)
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, "oci", fullArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("oci %s failed: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func (p *Provider) oracleListInstances(ctx context.Context) ([]remoteInstance, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return nil, err
	}
	compartmentID := p.oracleExtra(cfg, "compartmentId", "compartment_id", "compartment_ocid")
	if compartmentID == "" {
		return nil, fmt.Errorf("oracle requires compartment id: set extra.compartmentId")
	}

	out, err := p.oracleCLI(ctx, "compute", "instance", "list", "--all", "--compartment-id", compartmentID)
	if err != nil {
		return nil, err
	}
	var payload struct {
		Data []struct {
			ID                 string `json:"id"`
			DisplayName        string `json:"display-name"`
			LifecycleState     string `json:"lifecycle-state"`
			Shape              string `json:"shape"`
			TimeCreated        string `json:"time-created"`
			AvailabilityDomain string `json:"availability-domain"`
			Region             string `json:"region"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, err
	}
	instances := make([]remoteInstance, 0, len(payload.Data))
	for _, item := range payload.Data {
		id := strings.TrimSpace(item.ID)
		if id == "" {
			continue
		}
		ipv4, _ := p.oraclePublicIP(ctx, id)
		region := firstNonEmpty(strings.TrimSpace(item.Region), oracleRegionFromAD(item.AvailabilityDomain))
		instances = append(instances, remoteInstance{
			RawID:     id,
			ID:        p.cloudID(id),
			Label:     firstNonEmpty(item.DisplayName, "node"),
			Status:    strings.ToLower(strings.TrimSpace(item.LifecycleState)),
			Region:    region,
			Plan:      strings.TrimSpace(item.Shape),
			IPv4:      ipv4,
			CreatedAt: parseRFC3339(item.TimeCreated),
		})
	}
	return instances, nil
}

func (p *Provider) oracleGetInstance(ctx context.Context, remoteID string) (remoteInstance, error) {
	id := strings.TrimSpace(remoteID)
	if id == "" {
		return remoteInstance{}, cloud.ErrInstanceNotFound
	}
	out, err := p.oracleCLI(ctx, "compute", "instance", "get", "--instance-id", id)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "notfound") || strings.Contains(err.Error(), "404") {
			return remoteInstance{}, cloud.ErrInstanceNotFound
		}
		return remoteInstance{}, err
	}
	var payload struct {
		Data struct {
			ID                 string `json:"id"`
			DisplayName        string `json:"display-name"`
			LifecycleState     string `json:"lifecycle-state"`
			Shape              string `json:"shape"`
			TimeCreated        string `json:"time-created"`
			AvailabilityDomain string `json:"availability-domain"`
			Region             string `json:"region"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return remoteInstance{}, err
	}
	ipv4, _ := p.oraclePublicIP(ctx, id)
	region := firstNonEmpty(strings.TrimSpace(payload.Data.Region), oracleRegionFromAD(payload.Data.AvailabilityDomain))
	return remoteInstance{
		RawID:     id,
		ID:        p.cloudID(id),
		Label:     firstNonEmpty(payload.Data.DisplayName, "node"),
		Status:    strings.ToLower(strings.TrimSpace(payload.Data.LifecycleState)),
		Region:    region,
		Plan:      strings.TrimSpace(payload.Data.Shape),
		IPv4:      ipv4,
		CreatedAt: parseRFC3339(payload.Data.TimeCreated),
	}, nil
}

func (p *Provider) oraclePublicIP(ctx context.Context, instanceID string) (string, error) {
	out, err := p.oracleCLI(ctx, "compute", "instance", "list-vnics", "--instance-id", instanceID)
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			IsPrimary bool   `json:"is-primary"`
			PublicIP  string `json:"public-ip"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	for _, item := range payload.Data {
		if item.IsPrimary && strings.TrimSpace(item.PublicIP) != "" {
			return strings.TrimSpace(item.PublicIP), nil
		}
	}
	for _, item := range payload.Data {
		if strings.TrimSpace(item.PublicIP) != "" {
			return strings.TrimSpace(item.PublicIP), nil
		}
	}
	return "", nil
}

func (p *Provider) oracleCreateInstance(ctx context.Context, label, region, plan, userData string) (remoteInstance, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return remoteInstance{}, err
	}
	compartmentID := p.oracleExtra(cfg, "compartmentId", "compartment_id", "compartment_ocid")
	if compartmentID == "" {
		return remoteInstance{}, fmt.Errorf("oracle create requires extra.compartmentId")
	}
	subnetID := p.oracleExtra(cfg, "subnetId", "subnet_id", "subnet_ocid")
	if subnetID == "" {
		return remoteInstance{}, fmt.Errorf("oracle create requires extra.subnetId")
	}

	shape := strings.TrimSpace(plan)
	if shape == "" {
		shape = "VM.Standard.E2.1.Micro"
	}
	availabilityDomain := p.oracleExtra(cfg, "availabilityDomain", "availability_domain")
	if availabilityDomain == "" {
		ad, err := p.oracleResolveAvailabilityDomain(ctx, compartmentID)
		if err != nil {
			return remoteInstance{}, err
		}
		availabilityDomain = ad
	}
	imageID := p.oracleExtra(cfg, "imageId", "image_id", "image_ocid")
	if imageID == "" {
		imageID, err = p.oracleResolveImageID(ctx, compartmentID)
		if err != nil {
			return remoteInstance{}, err
		}
	}

	metaRaw, _ := json.Marshal(map[string]string{"user_data": base64.StdEncoding.EncodeToString([]byte(userData))})
	args := []string{
		"compute", "instance", "launch",
		"--compartment-id", compartmentID,
		"--availability-domain", availabilityDomain,
		"--shape", shape,
		"--subnet-id", subnetID,
		"--image-id", imageID,
		"--display-name", label,
		"--assign-public-ip", "true",
		"--metadata", string(metaRaw),
	}
	if strings.Contains(strings.ToLower(shape), ".flex") {
		shapeCfg := map[string]any{
			"ocpus":         1,
			"memory_in_gbs": 6,
		}
		if strings.Contains(strings.ToLower(shape), "standard3") {
			shapeCfg["memory_in_gbs"] = 8
		}
		if ocpus := p.oracleExtra(cfg, "ocpus", "oracle_ocpus"); ocpus != "" {
			if v, err := strconv.ParseFloat(ocpus, 64); err == nil && v > 0 {
				shapeCfg["ocpus"] = v
			}
		}
		if mem := p.oracleExtra(cfg, "memoryInGBs", "memory_in_gbs", "oracle_memory_gbs"); mem != "" {
			if v, err := strconv.ParseFloat(mem, 64); err == nil && v > 0 {
				shapeCfg["memory_in_gbs"] = v
			}
		}
		shapeCfgRaw, _ := json.Marshal(shapeCfg)
		args = append(args, "--shape-config", string(shapeCfgRaw))
	}

	out, err := p.oracleCLI(ctx, args...)
	if err != nil {
		return remoteInstance{}, err
	}
	var payload struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return remoteInstance{}, err
	}
	id := strings.TrimSpace(payload.Data.ID)
	if id == "" {
		return remoteInstance{}, fmt.Errorf("oracle create did not return instance id")
	}
	if inst, err := p.oracleGetInstance(ctx, id); err == nil {
		return inst, nil
	}
	return remoteInstance{
		RawID:     id,
		ID:        p.cloudID(id),
		Label:     label,
		Status:    "provisioning",
		Region:    region,
		Plan:      shape,
		CreatedAt: time.Now().UTC(),
	}, nil
}

func (p *Provider) oracleResolveAvailabilityDomain(ctx context.Context, compartmentID string) (string, error) {
	out, err := p.oracleCLI(ctx, "iam", "availability-domain", "list", "--compartment-id", compartmentID)
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			Name string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	if len(payload.Data) == 0 || strings.TrimSpace(payload.Data[0].Name) == "" {
		return "", fmt.Errorf("oracle returned no availability domains")
	}
	return strings.TrimSpace(payload.Data[0].Name), nil
}

func (p *Provider) oracleResolveImageID(ctx context.Context, compartmentID string) (string, error) {
	out, err := p.oracleCLI(ctx, "compute", "image", "list", "--all", "--compartment-id", compartmentID, "--operating-system", "Canonical Ubuntu", "--sort-by", "TIMECREATED", "--sort-order", "DESC")
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			ID               string `json:"id"`
			DisplayName      string `json:"display-name"`
			LifecycleState   string `json:"lifecycle-state"`
			OperatingSystem  string `json:"operating-system"`
			OperatingVersion string `json:"operating-system-version"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	pick := ""
	for _, image := range payload.Data {
		if strings.TrimSpace(image.ID) == "" {
			continue
		}
		if strings.ToUpper(strings.TrimSpace(image.LifecycleState)) != "AVAILABLE" {
			continue
		}
		if strings.Contains(strings.ToLower(image.DisplayName), "ubuntu") && strings.Contains(image.OperatingVersion, "22") {
			return strings.TrimSpace(image.ID), nil
		}
		if pick == "" {
			pick = strings.TrimSpace(image.ID)
		}
	}
	if pick == "" {
		return "", fmt.Errorf("oracle returned no usable images")
	}
	return pick, nil
}

func (p *Provider) oracleDestroyInstance(ctx context.Context, remoteID string) error {
	id := strings.TrimSpace(remoteID)
	if id == "" {
		return cloud.ErrInstanceNotFound
	}
	_, err := p.oracleCLI(ctx, "compute", "instance", "terminate", "--instance-id", id, "--force")
	if err != nil && !(strings.Contains(strings.ToLower(err.Error()), "notfound") || strings.Contains(err.Error(), "404")) {
		return err
	}
	return nil
}
