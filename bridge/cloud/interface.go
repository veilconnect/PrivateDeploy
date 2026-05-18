package cloud

import (
	"context"
	"time"
)

// CloudProvider defines the interface that all cloud service providers must implement
type CloudProvider interface {
	// Metadata
	Name() string
	DisplayName() string

	// Configuration
	LoadConfig() (*ProviderConfig, error)
	SaveConfig(config *ProviderConfig) error
	ValidateConfig(config *ProviderConfig) error

	// Regions
	ListRegions(ctx context.Context) ([]Region, error)

	// Plans (instance types)
	ListPlans(ctx context.Context, region string) ([]Plan, error)

	// Availability
	ListAvailability(ctx context.Context, region string) ([]string, error)

	// Instance Management
	ListInstances(ctx context.Context) ([]Instance, error)
	CreateInstance(ctx context.Context, opts *CreateInstanceOptions) (*Instance, error)
	DestroyInstance(ctx context.Context, instanceID string) error
	GetInstance(ctx context.Context, instanceID string) (*Instance, error)
}

// LatencyTester is implemented by providers that can benchmark regions.
type LatencyTester interface {
	TestRegionLatency(ctx context.Context, regionCode string) (*RegionLatency, error)
	TestAllRegions(ctx context.Context) ([]*RegionLatency, error)
	GetFastestRegion(ctx context.Context) (*RegionLatency, error)
}

// AccountStatusReporter is implemented by providers that can probe the upstream
// billing/verification state of the configured account. Providers that do not
// implement this interface are treated as always-deployable by the UI.
type AccountStatusReporter interface {
	GetAccountStatus(ctx context.Context) (*AccountStatus, error)
}

// AccountStatus describes the upstream account state for a configured cloud
// provider. The "active" state is the only one that unconditionally permits
// new deployments. Values are intentionally provider-agnostic so the UI can
// degrade uniformly across providers.
//
// State values:
//   - "active"      — normal, deploys permitted.
//   - "warning"     — account is usable but has an unresolved upstream warning
//     (e.g. billing reminder); deploys permitted with a UI banner.
//   - "locked"      — upstream has frozen new resource creation; deploys must be
//     refused at the bridge layer.
//   - "invalid_key" — API key is missing or rejected by the provider.
//   - "unknown"     — upstream probe failed for a transient reason; deploys are
//     permitted (fail-open) so an API hiccup does not freeze the UI.
type AccountStatus struct {
	State     string    `json:"state"`
	Message   string    `json:"message,omitempty"`
	CanDeploy bool      `json:"canDeploy"`
	CheckedAt time.Time `json:"checkedAt"`
}

// ProviderConfig holds provider-specific configuration
type ProviderConfig struct {
	Provider      string            `json:"provider"`         // "vultr", "digitalocean", etc.
	APIKey        string            `json:"apiKey,omitempty"` // API authentication key
	DefaultRegion string            `json:"defaultRegion"`    // Default region for deployments
	DefaultPlan   string            `json:"defaultPlan"`      // Default instance plan
	Extra         map[string]string `json:"extra,omitempty"`  // Provider-specific options
}

// Region represents a geographical region/datacenter
type Region struct {
	ID        string `json:"id"`        // Region identifier
	City      string `json:"city"`      // City name
	Country   string `json:"country"`   // Country name
	Continent string `json:"continent"` // Continent name
}

// RegionLatency represents measured network quality for a region.
type RegionLatency struct {
	Code    string  `json:"code"`    // Region code (nrt, fra, lax...)
	Name    string  `json:"name"`    // Human-readable region name
	IP      string  `json:"ip"`      // Probe IP
	Latency float64 `json:"latency"` // Average latency in milliseconds
	Loss    float64 `json:"loss"`    // Packet loss percentage (0-100)
	Status  string  `json:"status"`  // ok, timeout, error
}

// Plan represents an instance type/size
type Plan struct {
	ID          string   `json:"id"`                    // Plan identifier
	Description string   `json:"description,omitempty"` // Human-readable description
	RAM         int      `json:"ram"`                   // Memory in MB
	VCPUs       int      `json:"vcpus"`                 // Number of virtual CPUs
	Disk        int      `json:"disk"`                  // Disk size in GB
	Bandwidth   int      `json:"bandwidth"`             // Bandwidth in GB
	MonthlyCost float64  `json:"monthlyCost,omitempty"` // Monthly cost in USD
	HourlyCost  float64  `json:"hourlyCost,omitempty"`  // Hourly cost in USD
	Type        string   `json:"type,omitempty"`        // Plan type (e.g., "vc2", "s")
	Locations   []string `json:"locations,omitempty"`   // Available locations
}

// Instance represents a deployed cloud instance
type Instance struct {
	ID        string    `json:"id"`        // Instance identifier
	Provider  string    `json:"provider"`  // Cloud provider name
	Label     string    `json:"label"`     // Instance label/name
	Status    string    `json:"status"`    // Instance status
	Region    string    `json:"region"`    // Deployment region
	Plan      string    `json:"plan"`      // Instance plan
	OSID      int       `json:"osId"`      // Operating system ID
	IPv4      string    `json:"ipv4"`      // Primary IPv4 address
	IPv6      string    `json:"ipv6"`      // Primary IPv6 address
	Port      int       `json:"port"`      // Default SSH port
	Password  string    `json:"password"`  // Root password
	CreatedAt time.Time `json:"createdAt"` // Creation timestamp
	// ReplacedInstanceID identifies the stale local instance record that was
	// migrated to this live instance during refresh reconciliation.
	ReplacedInstanceID string `json:"replacedInstanceId,omitempty"`

	// Multi-protocol proxy configuration
	SSPort             int    `json:"ssPort,omitempty"`             // Shadowsocks port
	SSPassword         string `json:"ssPassword,omitempty"`         // Shadowsocks password
	HysteriaPort       int    `json:"hysteriaPort,omitempty"`       // Hysteria2 port
	HysteriaPassword   string `json:"hysteriaPassword,omitempty"`   // Hysteria2 password
	HysteriaServerName string `json:"hysteriaServerName,omitempty"` // Hysteria2 TLS server name
	HysteriaInsecure   *bool  `json:"hysteriaInsecure,omitempty"`   // Hysteria2 allow insecure TLS
	VLESSPort          int    `json:"vlessPort,omitempty"`          // VLESS port
	VLESSUUID          string `json:"vlessUUID,omitempty"`          // VLESS UUID
	VLESSPublicKey     string `json:"vlessPublicKey,omitempty"`     // VLESS Reality public key
	VLESSShortID       string `json:"vlessShortId,omitempty"`       // VLESS Reality short ID
	VLESSServerName    string `json:"vlessServerName,omitempty"`    // VLESS Reality SNI / handshake server
	TrojanPort         int    `json:"trojanPort,omitempty"`         // Trojan port
	TrojanPassword     string `json:"trojanPassword,omitempty"`     // Trojan password
	TrojanServerName   string `json:"trojanServerName,omitempty"`   // Trojan TLS server name
	TrojanInsecure     *bool  `json:"trojanInsecure,omitempty"`     // Trojan allow insecure TLS
	// VLESSRelayPort is a non-Reality, non-TLS plain VLESS inbound, deployed
	// alongside the Reality endpoint specifically for CDN front-ending. The
	// Cloudflare Worker forwards WS frames to this port over plain TCP; auth
	// is via the same VLESSUUID. 0 means the node was deployed with an older
	// userdata script and CDN front-ending is unavailable until re-deploy.
	VLESSRelayPort     int    `json:"vlessRelayPort,omitempty"`     // VLESS plain (CDN-relay) port
}

// CreateInstanceOptions contains options for creating a new instance
type CreateInstanceOptions struct {
	Label    string            `json:"label"`           // Instance label
	Region   string            `json:"region"`          // Deployment region
	Plan     string            `json:"plan"`            // Instance plan
	OSID     int               `json:"osId"`            // Operating system ID (optional)
	SSHKeyID string            `json:"sshKeyId"`        // SSH key ID (optional)
	Host     string            `json:"host,omitempty"`  // Target host for SSH deployment
	Extra    map[string]string `json:"extra,omitempty"` // Provider-specific options (SSH auth, etc.)
}

// InstanceRecord stores instance metadata for persistence
type InstanceRecord struct {
	Plan               string `json:"plan"`
	OSID               int    `json:"osId"`
	IPv4               string `json:"ipv4"`
	IPv6               string `json:"ipv6"`
	Port               int    `json:"port"`
	Password           string `json:"password"`
	CreatedAt          string `json:"createdAt"`
	SSPort             int    `json:"ssPort,omitempty"`
	SSPassword         string `json:"ssPassword,omitempty"`
	HysteriaPort       int    `json:"hysteriaPort,omitempty"`
	HysteriaPassword   string `json:"hysteriaPassword,omitempty"`
	HysteriaServerName string `json:"hysteriaServerName,omitempty"`
	HysteriaInsecure   *bool  `json:"hysteriaInsecure,omitempty"`
	VLESSPort          int    `json:"vlessPort,omitempty"`
	VLESSUUID          string `json:"vlessUUID,omitempty"`
	VLESSPublicKey     string `json:"vlessPublicKey,omitempty"`
	VLESSShortID       string `json:"vlessShortId,omitempty"`
	VLESSServerName    string `json:"vlessServerName,omitempty"`
	TrojanPort         int    `json:"trojanPort,omitempty"`
	TrojanPassword     string `json:"trojanPassword,omitempty"`
	TrojanServerName   string `json:"trojanServerName,omitempty"`
	TrojanInsecure     *bool  `json:"trojanInsecure,omitempty"`
	VLESSRelayPort     int    `json:"vlessRelayPort,omitempty"`
}
