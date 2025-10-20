package bridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/curve25519"
)

const (
	vultrAPIBaseURL     = "https://api.vultr.com/v2"
	vultrConfigFilePath = "data/cloud/vultr-config.json"
	vultrNodesFilePath  = "data/cloud/vultr-nodes.json"
)

var (
	errMissingVultrAPIKey = errors.New("Vultr API key is not configured")
	vultrHTTPClient       = &http.Client{Timeout: 60 * time.Second}
	vultrNodesMu          sync.Mutex
	vultrOSCache          []vultrOS
	vultrOSCacheTime      time.Time
	vultrOSCacheMu        sync.Mutex
	// Instances cache
	vultrInstancesCache     []VultrNode
	vultrInstancesCacheTime time.Time
	vultrInstancesCacheMu   sync.RWMutex
)

type VultrConfig struct {
	APIKey        string `json:"apiKey"`
	DefaultRegion string `json:"defaultRegion,omitempty"`
	DefaultPlan   string `json:"defaultPlan,omitempty"`
}

type vultrRegion struct {
	ID        string `json:"id"`
	City      string `json:"city"`
	Country   string `json:"country"`
	Continent string `json:"continent"`
}

type vultrPlan struct {
	ID          string   `json:"id"`
	Description string   `json:"description"`
	MemoryMB    int      `json:"ram"`
	VCPUs       int      `json:"vcpu_count"`
	DiskGB      int      `json:"disk"`
	BandwidthGB int      `json:"bandwidth"`
	MonthlyCost float64  `json:"monthly_cost"`
	HourlyCost  float64  `json:"hourly_cost"`
	Type        string   `json:"type"`
	Locations   []string `json:"locations"`
}

type vultrInstance struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Status    string `json:"status"`
	Region    string `json:"region"`
	MainIP    string `json:"main_ip"`
	V6MainIP  string `json:"v6_main_ip"`
	CreatedAt string `json:"created_at"`
}

type vultrOS struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Family string `json:"family"`
}

type vultrNodeRecord struct {
	InstanceID string `json:"instanceId"`
	Label      string `json:"label"`
	Region     string `json:"region"`
	Plan       string `json:"plan"`
	OSID       int    `json:"osId,omitempty"`
	Port       int    `json:"port"`     // Legacy: Shadowsocks port (for backward compatibility)
	Password   string `json:"password"` // Legacy: Shadowsocks password
	CreatedAt  string `json:"createdAt"`
	IPv4       string `json:"ipv4,omitempty"`
	IPv6       string `json:"ipv6,omitempty"`
	// Multi-protocol configuration
	SSPort           int    `json:"ssPort,omitempty"`
	SSPassword       string `json:"ssPassword,omitempty"`
	HysteriaPort     int    `json:"hysteriaPort,omitempty"`
	HysteriaPassword string `json:"hysteriaPassword,omitempty"`
	VLESSPort        int    `json:"vlessPort,omitempty"`
	VLESSUUID        string `json:"vlessUUID,omitempty"`
	VLESSPublicKey   string `json:"vlessPublicKey,omitempty"`
	VLESSShortID     string `json:"vlessShortId,omitempty"`
	TrojanPort       int    `json:"trojanPort,omitempty"`
	TrojanPassword   string `json:"trojanPassword,omitempty"`
}

type VultrNode struct {
	InstanceID string `json:"instanceId"`
	Label      string `json:"label"`
	Status     string `json:"status"`
	Region     string `json:"region"`
	Plan       string `json:"plan"`
	OSID       int    `json:"osId"`
	IPv4       string `json:"ipv4"`
	IPv6       string `json:"ipv6,omitempty"`
	Port       int    `json:"port"`     // Legacy: Shadowsocks port
	Password   string `json:"password"` // Legacy: Shadowsocks password
	CreatedAt  string `json:"createdAt"`
	// Multi-protocol configuration
	SSPort           int    `json:"ssPort,omitempty"`
	SSPassword       string `json:"ssPassword,omitempty"`
	HysteriaPort     int    `json:"hysteriaPort,omitempty"`
	HysteriaPassword string `json:"hysteriaPassword,omitempty"`
	VLESSPort        int    `json:"vlessPort,omitempty"`
	VLESSUUID        string `json:"vlessUUID,omitempty"`
	VLESSPublicKey   string `json:"vlessPublicKey,omitempty"`
	VLESSShortID     string `json:"vlessShortId,omitempty"`
	TrojanPort       int    `json:"trojanPort,omitempty"`
	TrojanPassword   string `json:"trojanPassword,omitempty"`
}

type createVultrInstanceOptions struct {
	Label  string `json:"label"`
	Region string `json:"region"`
	Plan   string `json:"plan"`
}

func loadVultrConfig() (*VultrConfig, error) {
	configPath := GetPath(vultrConfigFilePath)

	data, err := os.ReadFile(configPath)
	if errors.Is(err, os.ErrNotExist) {
		return &VultrConfig{}, nil
	}
	if err != nil {
		return nil, err
	}

	var cfg VultrConfig
	if len(data) == 0 {
		return &cfg, nil
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}

	return &cfg, nil
}

func saveVultrConfig(cfg *VultrConfig) error {
	configPath := GetPath(vultrConfigFilePath)
	if err := os.MkdirAll(filepath.Dir(configPath), os.ModePerm); err != nil {
		return err
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(configPath, data, 0o600)
}

func loadVultrNodes() (map[string]vultrNodeRecord, error) {
	nodesPath := GetPath(vultrNodesFilePath)

	data, err := os.ReadFile(nodesPath)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]vultrNodeRecord{}, nil
	}
	if err != nil {
		return nil, err
	}

	if len(data) == 0 {
		return map[string]vultrNodeRecord{}, nil
	}

	records := map[string]vultrNodeRecord{}
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, err
	}

	return records, nil
}

func saveVultrNodes(nodes map[string]vultrNodeRecord) error {
	nodesPath := GetPath(vultrNodesFilePath)
	if err := os.MkdirAll(filepath.Dir(nodesPath), os.ModePerm); err != nil {
		return err
	}

	data, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(nodesPath, data, 0o600)
}

func appendUniqueInt(list *[]int, candidate int) {
	for _, id := range *list {
		if id == candidate {
			return
		}
	}
	*list = append(*list, candidate)
}

func listVultrOperatingSystems(apiKey string) ([]vultrOS, error) {
	vultrOSCacheMu.Lock()
	defer vultrOSCacheMu.Unlock()

	if len(vultrOSCache) > 0 && time.Since(vultrOSCacheTime) < time.Hour {
		cached := make([]vultrOS, len(vultrOSCache))
		copy(cached, vultrOSCache)
		return cached, nil
	}

	res, err := vultrRequest(http.MethodGet, "/os", apiKey, nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		OperatingSystems []vultrOS `json:"os"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return nil, err
	}

	vultrOSCache = payload.OperatingSystems
	vultrOSCacheTime = time.Now()

	cached := make([]vultrOS, len(vultrOSCache))
	copy(cached, vultrOSCache)
	return cached, nil
}

func preferredVultrOSIDs(apiKey string) ([]int, error) {
	osList, err := listVultrOperatingSystems(apiKey)
	if err != nil {
		return nil, err
	}

	var result []int

	addMatches := func(predicate func(vultrOS) bool) {
		for _, operatingSystem := range osList {
			if predicate(operatingSystem) {
				appendUniqueInt(&result, operatingSystem.ID)
			}
		}
	}

	// Priority 1: Debian 11 (lightweight, works with 512MB)
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "11")
	})

	// Priority 2: Ubuntu 20.04 (may work with 512MB)
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "20.04")
	})

	// Priority 3: Debian 12
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "12")
	})

	// Priority 4: Ubuntu 22.04
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "22.04")
	})

	// Priority 5: Ubuntu 24.04 (requires 1000MB+)
	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "24.04")
	})

	// Priority 6: Any other Debian
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian")
	})

	// Priority 7: Any other Ubuntu
	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu")
	})

	// Priority 8: All other available systems
	for _, os := range osList {
		appendUniqueInt(&result, os.ID)
	}

	return result, nil
}

func randomPort() int {
	min := 20000
	max := 50000
	return min + mathrand.Intn(max-min)
}

func randomPassword(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

	buffer := make([]byte, length)
	if _, err := rand.Read(buffer); err != nil {
		for i := range buffer {
			buffer[i] = byte(mathrand.Intn(len(charset)))
		}
	}

	for i := range buffer {
		buffer[i] = charset[int(buffer[i])%len(charset)]
	}

	return string(buffer)
}

func generateUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		mathrand.Read(b)
	}

	// Set version (4) and variant bits
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80

	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func generateRealityKeyPair() (privateKey string, publicKey string) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		for i := range priv {
			priv[i] = byte(mathrand.Intn(256))
		}
	}

	// Clamp private key as required by RFC 7748
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64

	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		// Fallback: return empty keys so caller can handle
		return "", ""
	}

	// sing-box Reality requires URL-safe base64 encoding (RFC 4648)
	// Use RawURLEncoding (no padding) as per sing-box requirements
	privateKey = base64.RawURLEncoding.EncodeToString(priv)
	publicKey = base64.RawURLEncoding.EncodeToString(pub)
	return
}

func decodeVultrError(body []byte) string {
	type vultrErrorEnvelope struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}

	var env vultrErrorEnvelope
	if err := json.Unmarshal(body, &env); err == nil {
		if env.Error.Message != "" {
			return env.Error.Message
		}
		if len(env.Errors) > 0 && env.Errors[0].Message != "" {
			return env.Errors[0].Message
		}
	}

	reason := strings.TrimSpace(string(body))
	return reason
}

func vultrRequest(method, path, apiKey string, body any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(payload)
	}

	req, err := http.NewRequest(method, vultrAPIBaseURL+path, reader)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	return vultrHTTPClient.Do(req)
}

func parseVultrResponse(res *http.Response, v any) error {
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}

	if res.StatusCode >= 400 {
		reason := decodeVultrError(body)
		if reason == "" {
			reason = http.StatusText(res.StatusCode)
		}
		return fmt.Errorf("vultr api error (%d %s): %s", res.StatusCode, http.StatusText(res.StatusCode), reason)
	}

	if v == nil || len(body) == 0 {
		return nil
	}

	return json.Unmarshal(body, v)
}

func (a *App) GetVultrConfig() FlagResult {
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) SaveVultrConfig(configJSON string) FlagResult {
	var cfg VultrConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: "API key cannot be empty"}
	}

	if err := saveVultrConfig(&cfg); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func (a *App) ListVultrRegions() FlagResult {
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	res, err := vultrRequest(http.MethodGet, "/regions", cfg.APIKey, nil)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var payload struct {
		Regions []vultrRegion `json:"regions"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(payload.Regions)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListVultrAvailability(region string) FlagResult {
	fmt.Printf("[ListVultrAvailability] Called for region: %s\n", region)

	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}
	if strings.TrimSpace(region) == "" {
		return FlagResult{Flag: false, Data: "region is required"}
	}

	res, err := vultrRequest(http.MethodGet, fmt.Sprintf("/regions/%s/availability", region), cfg.APIKey, nil)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var payload struct {
		Availability map[string][]string `json:"availability"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	plansSet := make(map[string]struct{})
	for _, plans := range payload.Availability {
		for _, plan := range plans {
			plansSet[plan] = struct{}{}
		}
	}
	plans := make([]string, 0, len(plansSet))
	for plan := range plansSet {
		plans = append(plans, plan)
	}
	sort.Strings(plans)

	fmt.Printf("[ListVultrAvailability] Found %d available plans for region %s: %v\n", len(plans), region, plans)

	data, err := json.Marshal(plans)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListVultrPlans() FlagResult {
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	res, err := vultrRequest(http.MethodGet, "/plans", cfg.APIKey, nil)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	data, err := json.Marshal(payload.Plans)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) ListVultrInstances() FlagResult {
	fmt.Printf("[ListVultrInstances] Called\n")
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	// Check cache first (if less than 10 seconds old, return cached data)
	vultrInstancesCacheMu.RLock()
	if len(vultrInstancesCache) > 0 && time.Since(vultrInstancesCacheTime) < 10*time.Second {
		fmt.Printf("[ListVultrInstances] Returning cached data (%d instances)\n", len(vultrInstancesCache))
		cached := make([]VultrNode, len(vultrInstancesCache))
		copy(cached, vultrInstancesCache)
		vultrInstancesCacheMu.RUnlock()

		data, err := json.Marshal(cached)
		if err != nil {
			return FlagResult{Flag: false, Data: err.Error()}
		}
		return FlagResult{Flag: true, Data: string(data)}
	}
	vultrInstancesCacheMu.RUnlock()

	// Fetch from API
	fmt.Printf("[ListVultrInstances] Fetching from Vultr API...\n")
	res, err := vultrRequest(http.MethodGet, "/instances", cfg.APIKey, nil)
	if err != nil {
		fmt.Printf("[ListVultrInstances] API request failed: %v\n", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}
	fmt.Printf("[ListVultrInstances] API request successful\n")

	var payload struct {
		Instances []vultrInstance `json:"instances"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		fmt.Printf("[ListVultrInstances] Failed to parse response: %v\n", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}
	fmt.Printf("[ListVultrInstances] Found %d instances from API\n", len(payload.Instances))

	vultrNodesMu.Lock()
	records, err := loadVultrNodes()
	vultrNodesMu.Unlock()
	if err != nil {
		fmt.Printf("[ListVultrInstances] Failed to load node records: %v\n", err)
		return FlagResult{Flag: false, Data: err.Error()}
	}
	fmt.Printf("[ListVultrInstances] Loaded %d node records\n", len(records))

	result := make([]VultrNode, 0, len(payload.Instances))
	for _, inst := range payload.Instances {
		record, ok := records[inst.ID]
		if !ok {
			continue
		}
		node := VultrNode{
			InstanceID:       inst.ID,
			Label:            inst.Label,
			Status:           inst.Status,
			Region:           inst.Region,
			Plan:             record.Plan,
			OSID:             record.OSID,
			IPv4:             firstNonEmpty(inst.MainIP, record.IPv4),
			IPv6:             firstNonEmpty(inst.V6MainIP, record.IPv6),
			Port:             record.Port,
			Password:         record.Password,
			CreatedAt:        firstNonEmpty(record.CreatedAt, inst.CreatedAt),
			SSPort:           record.SSPort,
			SSPassword:       record.SSPassword,
			HysteriaPort:     record.HysteriaPort,
			HysteriaPassword: record.HysteriaPassword,
			VLESSPort:        record.VLESSPort,
			VLESSUUID:        record.VLESSUUID,
			VLESSPublicKey:   record.VLESSPublicKey,
			VLESSShortID:     record.VLESSShortID,
			TrojanPort:       record.TrojanPort,
			TrojanPassword:   record.TrojanPassword,
		}
		if node.IPv4 == "" {
			node.IPv4 = inst.MainIP
		}
		if node.IPv6 == "" {
			node.IPv6 = inst.V6MainIP
		}
		result = append(result, node)
	}

	// Update cache
	vultrInstancesCacheMu.Lock()
	vultrInstancesCache = result
	vultrInstancesCacheTime = time.Now()
	vultrInstancesCacheMu.Unlock()
	fmt.Printf("[ListVultrInstances] Returning %d instances\n", len(result))

	data, err := json.Marshal(result)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func getPlanRAM(apiKey, planID string) (int, error) {
	res, err := vultrRequest(http.MethodGet, "/plans", apiKey, nil)
	if err != nil {
		return 0, err
	}

	var payload struct {
		Plans []vultrPlan `json:"plans"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return 0, err
	}

	for _, plan := range payload.Plans {
		if plan.ID == planID {
			return plan.MemoryMB, nil
		}
	}

	return 0, fmt.Errorf("plan %s not found", planID)
}

func generateLightweightScript(ssPort int, ssPassword string) string {
	return fmt.Sprintf(`#!/bin/bash
# VeilDeploy Lightweight Deployment for Low-Memory VPS (512MB RAM)
# Protocol: Shadowsocks only (no Docker)
set -e
export DEBIAN_FRONTEND=noninteractive

LOGFILE="/var/log/veildeploy-init.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== VeilDeploy Lightweight Init Started at $(date) ==="
echo "Deploying Shadowsocks-only configuration for 512MB RAM VPS"

# Update and install minimal packages
echo "[1/3] Installing shadowsocks-libev and UFW..."
apt-get update -qq
apt-get install -y shadowsocks-libev ufw

# Configure UFW firewall
echo "[2/3] Configuring UFW firewall..."
ufw --force disable || true
ufw --force reset
ufw logging on
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow %d/tcp comment 'Shadowsocks-TCP'
ufw allow %d/udp comment 'Shadowsocks-UDP'
echo "y" | ufw enable

echo "Verifying firewall configuration..."
ufw status verbose

# Configure Shadowsocks
echo "[3/3] Configuring Shadowsocks server (port %d)..."
mkdir -p /etc/shadowsocks-libev

cat > /etc/shadowsocks-libev/config.json <<'SSEOF'
{
    "server": "0.0.0.0",
    "server_port": %d,
    "password": "%s",
    "method": "aes-256-gcm",
    "timeout": 300,
    "fast_open": true,
    "mode": "tcp_and_udp"
}
SSEOF

# Start shadowsocks-libev service
systemctl enable shadowsocks-libev
systemctl restart shadowsocks-libev

sleep 3
echo "Shadowsocks service status:"
systemctl status shadowsocks-libev --no-pager --lines=10 || journalctl -u shadowsocks-libev -n 20 --no-pager

# Verification
sleep 2
echo ""
echo "=== Deployment Summary ==="
echo "Firewall status:"
ufw status numbered
echo ""
echo "Shadowsocks service:"
echo "  Status: $(systemctl is-active shadowsocks-libev)"
echo ""
echo "Listening port:"
netstat -tlnup 2>/dev/null | grep ':%d ' || ss -tlnup | grep ':%d ' || echo "Warning: Port %d not yet listening"
echo ""
echo "Protocol Configuration:"
echo "  Shadowsocks: Port %d (TCP/UDP) - Password: %s"
echo ""
echo "=== VeilDeploy Lightweight Init Completed at $(date) ==="
`, ssPort, ssPort, ssPort, ssPort, ssPassword, ssPort, ssPort, ssPort, ssPort, ssPassword)
}

func (a *App) CreateVultrInstance(optionsJSON string) FlagResult {
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	var opts createVultrInstanceOptions
	if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	if opts.Label == "" || opts.Region == "" || opts.Plan == "" {
		return FlagResult{Flag: false, Data: "label, region and plan are required"}
	}

	// Get plan RAM to determine deployment strategy
	planRAM, err := getPlanRAM(cfg.APIKey, opts.Plan)
	if err != nil {
		fmt.Printf("[CreateVultrInstance] Warning: Could not determine plan RAM: %v. Defaulting to full deployment.\n", err)
		planRAM = 1024 // Default to assuming enough RAM
	}
	fmt.Printf("[CreateVultrInstance] Plan %s has %d MB RAM\n", opts.Plan, planRAM)

	preferredOSIDs, err := preferredVultrOSIDs(cfg.APIKey)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if len(preferredOSIDs) == 0 {
		return FlagResult{Flag: false, Data: "no operating systems available"}
	}

	basePort := randomPort()
	ssPassword := randomPassword(22)
	hysteriaPassword := randomPassword(22)
	trojanPassword := randomPassword(22)
	vlessUUID := generateUUID()

	// Port allocation: basePort, basePort+1, basePort+2, basePort+3
	ssPort := basePort
	hysteriaPort := basePort + 1
	vlessPort := basePort + 2
	trojanPort := basePort + 3

	var (
		userDataScript    string
		realityPrivateKey string
		realityPublicKey  string
		realityShortID    string
	)

	// Choose deployment script based on RAM
	if planRAM <= 600 {
		// Low-memory VPS: Use lightweight script (Shadowsocks only)
		fmt.Printf("[CreateVultrInstance] Using lightweight deployment for %dMB RAM\n", planRAM)
		userDataScript = generateLightweightScript(ssPort, ssPassword)
	} else {
		// Standard VPS: Use full multi-protocol script
		fmt.Printf("[CreateVultrInstance] Using full multi-protocol deployment for %dMB RAM\n", planRAM)

		// Generate Reality key materials before rendering script so we can persist them
		realityPrivateKey, realityPublicKey = generateRealityKeyPair()
		for attempts := 0; attempts < 3 && (realityPrivateKey == "" || realityPublicKey == ""); attempts++ {
			realityPrivateKey, realityPublicKey = generateRealityKeyPair()
		}
		if realityPrivateKey == "" || realityPublicKey == "" {
			return FlagResult{Flag: false, Data: "failed to generate Reality key pair"}
		}
		realityShortID = fmt.Sprintf("%016x", mathrand.Int63())

		userDataScript = fmt.Sprintf(`#!/bin/bash
# VeilDeploy Multi-Protocol Deployment Script
# Protocols: Shadowsocks, Hysteria2, VLESS-Reality, Trojan
set -e
export DEBIAN_FRONTEND=noninteractive

LOGFILE="/var/log/veildeploy-init.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== VeilDeploy Multi-Protocol Init Started at $(date) ==="

# Update and install packages
echo "[1/8] Installing Docker, UFW and required packages..."
apt-get update -qq
apt-get install -y docker.io ufw iptables openssl curl netstat-nat

# Start Docker
echo "[2/8] Starting Docker service..."
systemctl enable docker
systemctl start docker
sleep 3

# Generate self-signed certificates
echo "[3/8] Generating TLS certificates..."
mkdir -p /etc/veildeploy/{hysteria,trojan,vless}

# Certificate for Hysteria2
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/veildeploy/hysteria/key.pem \
  -out /etc/veildeploy/hysteria/cert.pem \
  -days 365 -subj "/CN=www.bing.com" 2>/dev/null

# Certificate for Trojan
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/veildeploy/trojan/key.pem \
  -out /etc/veildeploy/trojan/cert.pem \
  -days 365 -subj "/CN=www.microsoft.com" 2>/dev/null

# Configure UFW firewall
echo "[4/8] Configuring UFW firewall..."
ufw --force disable || true
ufw --force reset
ufw logging on
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow %[1]d/tcp comment 'Shadowsocks-TCP'
ufw allow %[1]d/udp comment 'Shadowsocks-UDP'
ufw allow %[2]d/udp comment 'Hysteria2'
ufw allow %[3]d/tcp comment 'VLESS-Reality'
ufw allow %[4]d/tcp comment 'Trojan'
echo "y" | ufw enable

echo "[5/8] Verifying firewall configuration..."
ufw status verbose

# Deploy Shadowsocks
echo "[6/8] Deploying Shadowsocks server (port %[1]d)..."
docker rm -f ss-server >/dev/null 2>&1 || true
docker pull teddysun/shadowsocks-libev
docker run -d --name ss-server --restart=always \
  -p %[1]d:%[1]d/tcp -p %[1]d:%[1]d/udp \
  teddysun/shadowsocks-libev ss-server \
  -s 0.0.0.0 -p %[1]d -k %[5]s -m aes-256-gcm

sleep 2
echo "Shadowsocks container status:"
docker ps -a --filter "name=ss-server" --format "{{.Names}}: {{.Status}}"

# Deploy Hysteria2
echo "[7/8] Deploying Hysteria2 server (port %[2]d)..."
cat > /etc/veildeploy/hysteria/config.yaml <<'HYSTEOF'
listen: :%[2]d
tls:
  cert: /etc/veildeploy/hysteria/cert.pem
  key: /etc/veildeploy/hysteria/key.pem
auth:
  type: password
  password: %[6]s
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
HYSTEOF

docker rm -f hysteria-server >/dev/null 2>&1 || true
docker pull tobyxdd/hysteria:latest
docker run -d --name hysteria-server --restart=always \
  -p %[2]d:%[2]d/udp \
  -v /etc/veildeploy/hysteria:/etc/veildeploy/hysteria \
  tobyxdd/hysteria:latest server -c /etc/veildeploy/hysteria/config.yaml

sleep 2
echo "Hysteria2 container status:"
docker ps -a --filter "name=hysteria-server" --format "{{.Names}}: {{.Status}}"
docker logs hysteria-server 2>&1 | tail -n 10

# Deploy VLESS-Reality with sing-box
echo "[8/8] Deploying VLESS-Reality server (port %[3]d)..."

# Install sing-box
SINGBOX_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name": "v\K[^"]+' || echo "1.10.0")
echo "Installing sing-box version ${SINGBOX_VERSION}..."
curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" -o /tmp/singbox.tar.gz
tar -xzf /tmp/singbox.tar.gz -C /tmp
find /tmp -name "sing-box" -type f -executable -exec mv {} /usr/local/bin/sing-box \;
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/singbox.tar.gz /tmp/sing-box-*

# Create VLESS configuration with pre-generated Reality keys
cat > /etc/veildeploy/vless/config.json <<VLESSEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": %[3]d,
    "users": [{
      "uuid": "%[8]s",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "www.microsoft.com",
          "server_port": 443
        },
        "private_key": "%[9]s",
        "short_id": ["%[10]s"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
VLESSEOF

# Store Reality client parameters for reference
cat > /etc/veildeploy/vless/reality.txt <<REALITYINFO
PublicKey: %[11]s
ShortID: %[10]s
REALITYINFO
chmod 600 /etc/veildeploy/vless/reality.txt

# Run sing-box as systemd service
cat > /etc/systemd/system/vless-server.service <<'SERVICEEOF'
[Unit]
Description=VLESS-Reality Server (sing-box)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/veildeploy/vless/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable vless-server
systemctl start vless-server

sleep 3
echo "VLESS-Reality service status:"
systemctl status vless-server --no-pager --lines=10 || journalctl -u vless-server -n 20 --no-pager

# Deploy Trojan with sing-box
echo "[9/9] Deploying Trojan server (port %[4]d)..."
cat > /etc/veildeploy/trojan/config.json <<'TROJANEOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "trojan",
    "tag": "trojan-in",
    "listen": "::",
    "listen_port": %[4]d,
    "users": [{
      "password": "%[7]s"
    }],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "key_path": "/etc/veildeploy/trojan/key.pem",
      "certificate_path": "/etc/veildeploy/trojan/cert.pem"
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct"
  }]
}
TROJANEOF

# Run Trojan as systemd service using sing-box
cat > /etc/systemd/system/trojan-server.service <<'TROJANSERVICE'
[Unit]
Description=Trojan Server (sing-box)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/veildeploy/trojan/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
TROJANSERVICE

systemctl daemon-reload
systemctl enable trojan-server
systemctl start trojan-server

sleep 3
echo "Trojan service status:"
systemctl status trojan-server --no-pager --lines=10 || journalctl -u trojan-server -n 20 --no-pager

# Verification and summary
sleep 5
echo ""
echo "=== Deployment Summary ==="
echo "Firewall status:"
ufw status numbered
echo ""
echo "Docker containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Systemd services:"
echo "  VLESS-Reality: $(systemctl is-active vless-server)"
echo "  Trojan: $(systemctl is-active trojan-server)"
echo ""
echo "Listening ports:"
netstat -tlnup 2>/dev/null | grep -E ':%[1]d |:%[2]d |:%[3]d |:%[4]d ' || ss -tlnup | grep -E ':%[1]d |:%[2]d |:%[3]d |:%[4]d ' || echo "Warning: Some ports not yet listening"
echo ""
echo "Protocol Configuration:"
echo "  [1] Shadowsocks:    Port %[1]d (TCP/UDP) - Password: %[5]s"
echo "  [2] Hysteria2:      Port %[2]d (UDP) - Password: %[6]s"
echo "  [3] VLESS-Reality:  Port %[3]d (TCP) - UUID: %[8]s"
echo "                     Public Key: %[11]s"
echo "                     Short ID: %[10]s"
echo "  [4] Trojan:         Port %[4]d (TCP) - Password: %[7]s"
echo ""
echo "=== VeilDeploy Multi-Protocol Init Completed at $(date) ==="
`,
			ssPort,                        // %[1]d
			hysteriaPort,                  // %[2]d
			vlessPort,                     // %[3]d
			trojanPort,                    // %[4]d
			shellEscape(ssPassword),       // %[5]s
			shellEscape(hysteriaPassword), // %[6]s
			shellEscape(trojanPassword),   // %[7]s
			vlessUUID,                     // %[8]s
			realityPrivateKey,             // %[9]s
			realityShortID,                // %[10]s
			realityPublicKey,              // %[11]s
		)
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	selectedOSID := 0
	var lastErr error

	for _, osID := range preferredOSIDs {
		requestBody := map[string]any{
			"region":      opts.Region,
			"plan":        opts.Plan,
			"os_id":       osID,
			"label":       opts.Label,
			"user_data":   base64.StdEncoding.EncodeToString([]byte(userDataScript)),
			"enable_ipv6": true,
		}

		res, err := vultrRequest(http.MethodPost, "/instances", cfg.APIKey, requestBody)
		if err != nil {
			lastErr = err
			continue
		}

		var attempt struct {
			Instance vultrInstance `json:"instance"`
		}
		if err := parseVultrResponse(res, &attempt); err != nil {
			msg := strings.ToLower(err.Error())
			if strings.Contains(msg, "os_id") {
				lastErr = err
				continue
			}
			return FlagResult{Flag: false, Data: err.Error()}
		}

		payload = attempt
		selectedOSID = osID
		lastErr = nil
		break
	}

	if lastErr != nil {
		return FlagResult{Flag: false, Data: lastErr.Error()}
	}

	instanceID := payload.Instance.ID

	vultrNodesMu.Lock()
	records, err := loadVultrNodes()
	if err != nil {
		vultrNodesMu.Unlock()
		return FlagResult{Flag: false, Data: err.Error()}
	}

	// Save record with appropriate protocol information based on RAM
	nodeRecord := vultrNodeRecord{
		InstanceID: instanceID,
		Label:      opts.Label,
		Region:     opts.Region,
		Plan:       opts.Plan,
		OSID:       selectedOSID,
		Port:       ssPort,     // Legacy compatibility: use SS port
		Password:   ssPassword, // Legacy compatibility: use SS password
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
		SSPort:     ssPort,
		SSPassword: ssPassword,
	}

	// Only add multi-protocol config for high-RAM plans
	if planRAM > 600 {
		nodeRecord.HysteriaPort = hysteriaPort
		nodeRecord.HysteriaPassword = hysteriaPassword
		nodeRecord.VLESSPort = vlessPort
		nodeRecord.VLESSUUID = vlessUUID
		nodeRecord.VLESSPublicKey = realityPublicKey
		nodeRecord.VLESSShortID = realityShortID
		nodeRecord.TrojanPort = trojanPort
		nodeRecord.TrojanPassword = trojanPassword
	}

	records[instanceID] = nodeRecord

	if err := saveVultrNodes(records); err != nil {
		vultrNodesMu.Unlock()
		return FlagResult{Flag: false, Data: err.Error()}
	}
	vultrNodesMu.Unlock()

	instance, err := waitForVultrInstance(cfg.APIKey, instanceID, 15*time.Minute)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	vultrNodesMu.Lock()
	records, err = loadVultrNodes()
	if err == nil {
		if record, ok := records[instanceID]; ok {
			record.IPv4 = instance.MainIP
			record.IPv6 = instance.V6MainIP
			records[instanceID] = record
			_ = saveVultrNodes(records)
		}
	}
	vultrNodesMu.Unlock()

	// Log detected IP addresses
	fmt.Printf("[CreateVultrInstance] Instance %s has IPv4: %s, IPv6: %s\n",
		instanceID, instance.MainIP, instance.V6MainIP)

	// Build result with appropriate protocol information
	result := VultrNode{
		InstanceID: instance.ID,
		Label:      instance.Label,
		Status:     instance.Status,
		Region:     instance.Region,
		Plan:       opts.Plan,
		OSID:       selectedOSID,
		IPv4:       instance.MainIP,
		IPv6:       instance.V6MainIP,
		Port:       ssPort,     // Legacy compatibility
		Password:   ssPassword, // Legacy compatibility
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
		SSPort:     ssPort,
		SSPassword: ssPassword,
	}

	// Only add multi-protocol config for high-RAM plans
	if planRAM > 600 {
		result.HysteriaPort = hysteriaPort
		result.HysteriaPassword = hysteriaPassword
		result.VLESSPort = vlessPort
		result.VLESSUUID = vlessUUID
		result.VLESSPublicKey = realityPublicKey
		result.VLESSShortID = realityShortID
		result.TrojanPort = trojanPort
		result.TrojanPassword = trojanPassword
	}

	data, err := json.Marshal(result)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
}

func (a *App) DestroyVultrInstance(instanceID string) FlagResult {
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	res, err := vultrRequest(http.MethodDelete, "/instances/"+instanceID, cfg.APIKey, nil)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if err := parseVultrResponse(res, nil); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	vultrNodesMu.Lock()
	defer vultrNodesMu.Unlock()

	records, err := loadVultrNodes()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	delete(records, instanceID)
	if err := saveVultrNodes(records); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: "Success"}
}

func waitForVultrInstance(apiKey, instanceID string, timeout time.Duration) (vultrInstance, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	var lastErr error

	for {
		select {
		case <-ctx.Done():
			if lastErr != nil {
				return vultrInstance{}, lastErr
			}
			return vultrInstance{}, errors.New("timeout waiting for instance to become active")
		case <-ticker.C:
			inst, err := getVultrInstance(apiKey, instanceID)
			if err != nil {
				lastErr = err
				continue
			}
			if inst.Status == "active" && inst.MainIP != "" {
				return inst, nil
			}
		}
	}
}

func getVultrInstance(apiKey, instanceID string) (vultrInstance, error) {
	res, err := vultrRequest(http.MethodGet, "/instances/"+instanceID, apiKey, nil)
	if err != nil {
		return vultrInstance{}, err
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return vultrInstance{}, err
	}

	return payload.Instance, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func shellEscape(input string) string {
	if input == "" {
		return "''"
	}
	if strings.ContainsAny(input, " \t\n\\\"'`$") {
		return "'" + strings.ReplaceAll(input, "'", "'\\''") + "'"
	}
	return input
}

func init() {
	mathrand.Seed(time.Now().UnixNano())
}
