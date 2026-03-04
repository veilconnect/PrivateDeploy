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

// ProviderConfig holds provider-specific configuration
type ProviderConfig struct {
	Provider      string            `json:"provider"`       // "vultr", "digitalocean", etc.
	APIKey        string            `json:"apiKey,omitempty"` // API authentication key
	DefaultRegion string            `json:"defaultRegion"`  // Default region for deployments
	DefaultPlan   string            `json:"defaultPlan"`    // Default instance plan
	Extra         map[string]string `json:"extra,omitempty"` // Provider-specific options
}

// Region represents a geographical region/datacenter
type Region struct {
	ID        string `json:"id"`        // Region identifier
	City      string `json:"city"`      // City name
	Country   string `json:"country"`   // Country name
	Continent string `json:"continent"` // Continent name
}

// Plan represents an instance type/size
type Plan struct {
	ID          string  `json:"id"`                    // Plan identifier
	Description string  `json:"description,omitempty"` // Human-readable description
	RAM         int     `json:"ram"`                   // Memory in MB
	VCPUs       int     `json:"vcpus"`                 // Number of virtual CPUs
	Disk        int     `json:"disk"`                  // Disk size in GB
	Bandwidth   int     `json:"bandwidth"`             // Bandwidth in GB
	MonthlyCost float64 `json:"monthlyCost,omitempty"` // Monthly cost in USD
	HourlyCost  float64 `json:"hourlyCost,omitempty"`  // Hourly cost in USD
	Type        string  `json:"type,omitempty"`        // Plan type (e.g., "vc2", "s")
	Locations   []string `json:"locations,omitempty"`  // Available locations
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

	// Multi-protocol proxy configuration
	SSPort           int    `json:"ssPort,omitempty"`           // Shadowsocks port
	SSPassword       string `json:"ssPassword,omitempty"`       // Shadowsocks password
	HysteriaPort     int    `json:"hysteriaPort,omitempty"`     // Hysteria2 port
	HysteriaPassword string `json:"hysteriaPassword,omitempty"` // Hysteria2 password
	VLESSPort        int    `json:"vlessPort,omitempty"`        // VLESS port
	VLESSUUID        string `json:"vlessUUID,omitempty"`        // VLESS UUID
	VLESSPublicKey   string `json:"vlessPublicKey,omitempty"`   // VLESS Reality public key
	VLESSShortID     string `json:"vlessShortId,omitempty"`     // VLESS Reality short ID
	TrojanPort       int    `json:"trojanPort,omitempty"`       // Trojan port
	TrojanPassword   string `json:"trojanPassword,omitempty"`   // Trojan password
}

// CreateInstanceOptions contains options for creating a new instance
type CreateInstanceOptions struct {
	Label    string            `json:"label"`              // Instance label
	Region   string            `json:"region"`             // Deployment region
	Plan     string            `json:"plan"`               // Instance plan
	OSID     int               `json:"osId"`               // Operating system ID (optional)
	SSHKeyID string            `json:"sshKeyId"`           // SSH key ID (optional)
	Host     string            `json:"host,omitempty"`     // Target host for SSH deployment
	Extra    map[string]string `json:"extra,omitempty"`    // Provider-specific options (SSH auth, etc.)
}

// InstanceRecord stores instance metadata for persistence
type InstanceRecord struct {
	Plan             string    `json:"plan"`
	OSID             int       `json:"osId"`
	IPv4             string    `json:"ipv4"`
	IPv6             string    `json:"ipv6"`
	Port             int       `json:"port"`
	Password         string    `json:"password"`
	CreatedAt        string    `json:"createdAt"`
	SSPort           int       `json:"ssPort,omitempty"`
	SSPassword       string    `json:"ssPassword,omitempty"`
	HysteriaPort     int       `json:"hysteriaPort,omitempty"`
	HysteriaPassword string    `json:"hysteriaPassword,omitempty"`
	VLESSPort        int       `json:"vlessPort,omitempty"`
	VLESSUUID        string    `json:"vlessUUID,omitempty"`
	VLESSPublicKey   string    `json:"vlessPublicKey,omitempty"`
	VLESSShortID     string    `json:"vlessShortId,omitempty"`
	TrojanPort       int       `json:"trojanPort,omitempty"`
	TrojanPassword   string    `json:"trojanPassword,omitempty"`
}
