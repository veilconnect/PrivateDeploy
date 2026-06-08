// Package catalog implements the cloud.CloudProvider interface for several
// secondary clouds (Hetzner, Linode, Scaleway, UpCloud, Contabo, Oracle) by
// dispatching off Provider.name. Plan and region catalogs ship as static data
// where the upstream API doesn't justify a live call.
//
// Files in this package:
//
//   - provider.go            — package shell: types, all New* constructors,
//                              CloudProvider interface methods, apiRequest.
//   - listing.go             — per-provider ListRegions / ListPlans dispatch.
//   - remote_instances.go    — per-provider lifecycle dispatch (list / create /
//                              get / wait / record-to-instance projection).
//   - provider_scaleway.go   — Scaleway-specific lookups (project, image, get).
//   - provider_upcloud.go    — UpCloud template-storage lookup.
//   - provider_contabo.go    — Contabo OAuth + API calls.
//   - provider_oracle.go     — Oracle OCI CLI shell-out.
//   - provider_helpers.go    — small shared utilities (URL building, parsing).
//   - provider_config.go     — config Load/Save/Validate + key-blob parsing.
//   - provider_records.go    — local node-record persistence.
package catalog

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
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
		client: &http.Client{
			Timeout: catalogDefaultHTTPTimeout,
			Transport: &http.Transport{
				Proxy: nil,
				DialContext: (&net.Dialer{
					Timeout:   30 * time.Second,
					KeepAlive: 30 * time.Second,
				}).DialContext,
				TLSHandshakeTimeout:   10 * time.Second,
				ExpectContinueTimeout: 1 * time.Second,
				IdleConnTimeout:       90 * time.Second,
			},
		},
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
	vlessRelayPort := ports.VLESSRelayPort

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
		VLESSRelayPort:   vlessRelayPort,
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
		VLESSRelayPort:     vlessRelayPort,
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
