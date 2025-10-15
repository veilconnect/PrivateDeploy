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
	ID          string `json:"id"`
	Description string `json:"description"`
	MemoryMB    int    `json:"memory"`
	VCPUs       int    `json:"vcpu_count"`
	DiskGB      int    `json:"disk"`
	BandwidthGB int    `json:"bandwidth"`
}

type vultrInstance struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Status    string `json:"status"`
	Region    string `json:"region"`
	MainIP    string `json:"main_ip"`
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
	Port       int    `json:"port"`
	Password   string `json:"password"`
	CreatedAt  string `json:"createdAt"`
	IPv4       string `json:"ipv4,omitempty"`
}

type VultrNode struct {
	InstanceID string `json:"instanceId"`
	Label      string `json:"label"`
	Status     string `json:"status"`
	Region     string `json:"region"`
	Plan       string `json:"plan"`
	OSID       int    `json:"osId"`
	IPv4       string `json:"ipv4"`
	Port       int    `json:"port"`
	Password   string `json:"password"`
	CreatedAt  string `json:"createdAt"`
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

	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "24.04")
	})

	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu") && strings.Contains(name, "22.04")
	})

	addMatches(func(os vultrOS) bool {
		name := strings.ToLower(os.Name)
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian") && strings.Contains(name, "12")
	})

	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "ubuntu")
	})

	addMatches(func(os vultrOS) bool {
		family := strings.ToLower(os.Family)
		return strings.Contains(family, "debian")
	})

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
	cfg, err := loadVultrConfig()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if strings.TrimSpace(cfg.APIKey) == "" {
		return FlagResult{Flag: false, Data: errMissingVultrAPIKey.Error()}
	}

	res, err := vultrRequest(http.MethodGet, "/instances", cfg.APIKey, nil)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	var payload struct {
		Instances []vultrInstance `json:"instances"`
	}
	if err := parseVultrResponse(res, &payload); err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	vultrNodesMu.Lock()
	defer vultrNodesMu.Unlock()

	records, err := loadVultrNodes()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	result := make([]VultrNode, 0, len(payload.Instances))
	for _, inst := range payload.Instances {
		record, ok := records[inst.ID]
		if !ok {
			continue
		}
		node := VultrNode{
			InstanceID: inst.ID,
			Label:      inst.Label,
			Status:     inst.Status,
			Region:     inst.Region,
			Plan:       record.Plan,
			OSID:       record.OSID,
			IPv4:       firstNonEmpty(inst.MainIP, record.IPv4),
			Port:       record.Port,
			Password:   record.Password,
			CreatedAt:  firstNonEmpty(record.CreatedAt, inst.CreatedAt),
		}
		if node.IPv4 == "" {
			node.IPv4 = inst.MainIP
		}
		result = append(result, node)
	}

	data, err := json.Marshal(result)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(data)}
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

	preferredOSIDs, err := preferredVultrOSIDs(cfg.APIKey)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	if len(preferredOSIDs) == 0 {
		return FlagResult{Flag: false, Data: "no operating systems available"}
	}

	port := randomPort()
	password := randomPassword(22)

	userDataScript := fmt.Sprintf(`#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
docker rm -f ss-server >/dev/null 2>&1 || true
docker run -d --name ss-server --restart=always -p %[1]d:%[1]d/tcp -p %[1]d:%[1]d/udp teddysun/shadowsocks-libev -s 0.0.0.0 -p %[1]d -k %[2]s -m aes-256-gcm
`,
		port,
		shellEscape(password),
	)

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

	records[instanceID] = vultrNodeRecord{
		InstanceID: instanceID,
		Label:      opts.Label,
		Region:     opts.Region,
		Plan:       opts.Plan,
		OSID:       selectedOSID,
		Port:       port,
		Password:   password,
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
	}

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
			records[instanceID] = record
			_ = saveVultrNodes(records)
		}
	}
	vultrNodesMu.Unlock()

	result := VultrNode{
		InstanceID: instance.ID,
		Label:      instance.Label,
		Status:     instance.Status,
		Region:     instance.Region,
		Plan:       opts.Plan,
		OSID:       selectedOSID,
		IPv4:       instance.MainIP,
		Port:       port,
		Password:   password,
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
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
