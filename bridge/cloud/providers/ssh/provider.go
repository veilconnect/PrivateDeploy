package ssh

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	mathrand "math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"

	gossh "golang.org/x/crypto/ssh"
)

const (
	configFileRelPath = "data/cloud/ssh-config.json"
	nodesFileRelPath  = "data/cloud/ssh-nodes.json"
)

var sshNodesMu sync.Mutex

// nodeRecord stores SSH node data for JSON persistence.
type nodeRecord struct {
	cloud.InstanceRecord
	InstanceID string `json:"instanceId"`
	Label      string `json:"label"`
	Host       string `json:"host"`
}

// Provider implements cloud.CloudProvider for SSH-based deployment.
type Provider struct {
	config     *cloud.ProviderConfig
	configPath string
	nodesPath  string

	// eventEmitter is called with (eventName, data...) to push progress events.
	// Set by the bridge layer via SetEventEmitter.
	eventEmitter func(eventName string, data ...interface{})
}

// New creates a new SSH provider instance.
func New(config *cloud.ProviderConfig) *Provider {
	if config == nil {
		config = &cloud.ProviderConfig{
			Provider: "ssh",
		}
	}

	basePath := os.Getenv("PRIVATEDEPLOY_BASE_PATH")
	if basePath == "" {
		basePath, _ = os.Getwd()
	}

	return &Provider{
		config:     config,
		configPath: filepath.Join(basePath, configFileRelPath),
		nodesPath:  filepath.Join(basePath, nodesFileRelPath),
	}
}

// SetEventEmitter sets the callback used to push Wails events.
func (p *Provider) SetEventEmitter(fn func(eventName string, data ...interface{})) {
	p.eventEmitter = fn
}

func (p *Provider) emit(event string, data ...interface{}) {
	if p.eventEmitter != nil {
		p.eventEmitter(event, data...)
	}
}

// Name returns the provider identifier.
func (p *Provider) Name() string { return "ssh" }

// DisplayName returns the human-readable provider name.
func (p *Provider) DisplayName() string { return "SSH 服务器" }

// LoadConfig loads the SSH configuration from file.
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		return &cloud.ProviderConfig{Provider: "ssh"}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	if len(data) == 0 {
		return &cloud.ProviderConfig{Provider: "ssh"}, nil
	}

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	p.config = &cfg
	return &cfg, nil
}

// SaveConfig persists the SSH configuration to file.
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config.Provider != "ssh" {
		return fmt.Errorf("invalid provider: expected ssh, got %s", config.Provider)
	}

	if err := os.MkdirAll(filepath.Dir(p.configPath), os.ModePerm); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := os.WriteFile(p.configPath, data, 0o600); err != nil {
		return fmt.Errorf("failed to write config: %w", err)
	}

	p.config = config
	return nil
}

// ValidateConfig validates the SSH configuration.
// SSH provider does NOT require an APIKey — it uses host+auth from Extra.
func (p *Provider) ValidateConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	if config.Provider != "ssh" {
		return fmt.Errorf("invalid provider: expected ssh, got %s", config.Provider)
	}
	// SSH doesn't need APIKey; host/auth info is in Extra and provided per-deploy
	return nil
}

// ListRegions returns an empty slice — SSH has no region concept.
func (p *Provider) ListRegions(ctx context.Context) ([]cloud.Region, error) {
	return []cloud.Region{}, nil
}

// ListPlans returns an empty slice — SSH has no plan concept.
func (p *Provider) ListPlans(ctx context.Context, region string) ([]cloud.Plan, error) {
	return []cloud.Plan{}, nil
}

// ListAvailability returns an empty slice.
func (p *Provider) ListAvailability(ctx context.Context, region string) ([]string, error) {
	return []string{}, nil
}

// ListInstances loads persisted SSH node records.
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	dirty := false
	instances := make([]cloud.Instance, 0, len(records))
	for id, rec := range records {
		if ensureManagedTLSDefaults(&rec.InstanceRecord) {
			records[id] = rec
			dirty = true
		}
		instances = append(instances, cloud.Instance{
			ID:                 rec.InstanceID,
			Provider:           "ssh",
			Label:              rec.Label,
			Status:             "active",
			IPv4:               rec.IPv4,
			IPv6:               rec.IPv6,
			Port:               rec.Port,
			CreatedAt:          parseTime(rec.CreatedAt),
			SSPort:             rec.SSPort,
			SSPassword:         rec.SSPassword,
			HysteriaPort:       rec.HysteriaPort,
			HysteriaPassword:   rec.HysteriaPassword,
			HysteriaServerName: rec.HysteriaServerName,
			HysteriaInsecure:   rec.HysteriaInsecure,
			VLESSPort:          rec.VLESSPort,
			VLESSUUID:          rec.VLESSUUID,
			VLESSPublicKey:     rec.VLESSPublicKey,
			VLESSShortID:       rec.VLESSShortID,
			VLESSServerName:    rec.VLESSServerName,
			TrojanPort:         rec.TrojanPort,
			TrojanPassword:     rec.TrojanPassword,
			TrojanServerName:   rec.TrojanServerName,
			TrojanInsecure:     rec.TrojanInsecure,
		})
	}

	if dirty {
		_ = p.saveNodeRecords(records)
	}

	return instances, nil
}

// CreateInstance deploys multi-protocol proxies to a server via SSH.
// SSH-specific fields come from opts.Extra or from the provider config.Extra:
//
//	host, port, username, authMethod ("password"|"key"), password, privateKey
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	// Merge SSH connection params: opts.Extra overrides config.Extra
	extra := mergeExtra(p.config.Extra, opts.Extra)
	tuning := deploy.ResolveDeploymentTuning(extra)

	host := extra["host"]
	if host == "" {
		return nil, fmt.Errorf("SSH host is required (set extra.host)")
	}

	portStr := extra["port"]
	sshPort := 22
	if portStr != "" {
		fmt.Sscanf(portStr, "%d", &sshPort)
	}

	username := extra["username"]
	if username == "" {
		username = "root"
	}

	authMethod, err := resolveAuth(extra)
	if err != nil {
		return nil, err
	}

	label := opts.Label
	if label == "" {
		label = fmt.Sprintf("ssh-%s", host)
	}

	instanceID := fmt.Sprintf("cloud-ssh-%s-%d", strings.ReplaceAll(host, ".", "-"), time.Now().Unix())

	// 1. Connect
	p.emit("cloud:ssh:progress", instanceID, "connecting", "正在连接到服务器...")
	log.Printf("[SSHProvider] Connecting to %s:%d as %s", host, sshPort, username)

	session, err := NewSession(host, sshPort, username, authMethod)
	if err != nil {
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("连接失败: %v", err))
		return nil, fmt.Errorf("SSH connection failed: %w", err)
	}
	defer session.Close()

	// 2. Detect server environment
	p.emit("cloud:ssh:progress", instanceID, "detecting", "正在检测服务器环境...")
	info, _ := session.DetectServer()
	log.Printf("[SSHProvider] Server: OS=%s Arch=%s RAM=%dMB", info.OS, info.Arch, info.Memory)

	// 3. Generate credentials
	p.emit("cloud:ssh:progress", instanceID, "generating", "正在生成部署参数...")

	ports := deploy.AllocatePorts(tuning.PortProfile)
	ssPort := ports.SSPort
	hysteriaPort := ports.HysteriaPort
	vlessPort := ports.VLESSPort
	trojanPort := ports.TrojanPort

	ssPassword := deploy.GenerateRandomPassword(16)
	hysteriaPassword := deploy.GenerateRandomPassword(22)
	vlessUUID := deploy.GenerateUUID()
	trojanPassword := deploy.GenerateRandomPassword(22)

	realityPrivateKey, realityPublicKey, err := deploy.GenerateRealityKeyPair()
	if err != nil {
		log.Printf("[SSHProvider] Warning: Reality keypair generation failed: %v", err)
		realityPrivateKey = ""
		realityPublicKey = ""
	}
	realityShortID := fmt.Sprintf("%016x", mathrand.Int63())

	// 4. Generate and execute deployment script
	var script string
	if info.Memory > 0 && info.Memory <= 600 {
		p.emit("cloud:ssh:progress", instanceID, "deploying", "内存不足，部署轻量模式 (仅 Shadowsocks)...")
		script = deploy.GenerateLightweightScript(ssPort, ssPassword)
	} else {
		p.emit("cloud:ssh:progress", instanceID, "deploying", "正在部署多协议代理 (SS + Hysteria2 + VLESS + Trojan)...")
		script = deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
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
	}

	// Run script with progress output
	var outputBuf bytes.Buffer
	progressWriter := &progressWriter{
		buf:        &outputBuf,
		instanceID: instanceID,
		emitter:    p.emit,
	}

	log.Printf("[SSHProvider] Executing deployment script on %s...", host)
	if err := session.RunScript(script, progressWriter); err != nil {
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("部署脚本执行失败: %v", err))
		return nil, fmt.Errorf("deployment script failed: %w\noutput:\n%s", err, outputBuf.String())
	}

	// 5. Verify ports
	p.emit("cloud:ssh:progress", instanceID, "verifying", "正在验证端口...")
	expectedPorts := []int{ssPort}
	isMulti := info.Memory == 0 || info.Memory > 600
	if isMulti {
		expectedPorts = append(expectedPorts, hysteriaPort, vlessPort, trojanPort)
	}

	// Poll for ports to come up (max 60 seconds)
	var portsOpen map[int]bool
	for attempt := 0; attempt < 6; attempt++ {
		portsOpen, _ = session.CheckPorts(expectedPorts)
		allOpen := true
		for _, open := range portsOpen {
			if !open {
				allOpen = false
				break
			}
		}
		if allOpen {
			break
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(10 * time.Second):
		}
	}

	// 6. Build instance and save record
	instance := &cloud.Instance{
		ID:         instanceID,
		Provider:   "ssh",
		Label:      label,
		Status:     "active",
		IPv4:       host,
		Port:       sshPort,
		CreatedAt:  time.Now(),
		SSPort:     ssPort,
		SSPassword: ssPassword,
	}

	if isMulti {
		instance.HysteriaPort = hysteriaPort
		instance.HysteriaPassword = hysteriaPassword
		instance.HysteriaServerName = tuning.HysteriaServerName
		instance.HysteriaInsecure = deploy.BoolPtr(tuning.HysteriaInsecure)
		instance.VLESSPort = vlessPort
		instance.VLESSUUID = vlessUUID
		instance.VLESSPublicKey = realityPublicKey
		instance.VLESSShortID = realityShortID
		instance.VLESSServerName = tuning.VLESSServerName
		instance.TrojanPort = trojanPort
		instance.TrojanPassword = trojanPassword
		instance.TrojanServerName = tuning.TrojanServerName
		instance.TrojanInsecure = deploy.BoolPtr(tuning.TrojanInsecure)
	}

	// Persist node record
	records, err := p.loadNodeRecords()
	if err != nil {
		records = make(map[string]nodeRecord)
	}

	records[instanceID] = nodeRecord{
		InstanceID: instanceID,
		Label:      label,
		Host:       host,
		InstanceRecord: cloud.InstanceRecord{
			Plan:               "ssh-deploy",
			IPv4:               host,
			Port:               sshPort,
			CreatedAt:          time.Now().Format(time.RFC3339),
			SSPort:             ssPort,
			SSPassword:         ssPassword,
			HysteriaPort:       instance.HysteriaPort,
			HysteriaPassword:   instance.HysteriaPassword,
			HysteriaServerName: instance.HysteriaServerName,
			HysteriaInsecure:   instance.HysteriaInsecure,
			VLESSPort:          instance.VLESSPort,
			VLESSUUID:          instance.VLESSUUID,
			VLESSPublicKey:     instance.VLESSPublicKey,
			VLESSShortID:       instance.VLESSShortID,
			VLESSServerName:    instance.VLESSServerName,
			TrojanPort:         instance.TrojanPort,
			TrojanPassword:     instance.TrojanPassword,
			TrojanServerName:   instance.TrojanServerName,
			TrojanInsecure:     instance.TrojanInsecure,
		},
	}

	if err := p.saveNodeRecords(records); err != nil {
		log.Printf("[SSHProvider] Warning: failed to save node record: %v", err)
	}

	p.emit("cloud:ssh:progress", instanceID, "ready", "部署完成！")
	log.Printf("[SSHProvider] Deployment complete for %s (ID: %s)", host, instanceID)
	return instance, nil
}

// DestroyInstance SSH-connects to stop services, then removes the local record.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	records, err := p.loadNodeRecords()
	if err != nil {
		return err
	}

	rec, ok := records[instanceID]
	if !ok {
		return cloud.ErrInstanceNotFound
	}

	// Try to SSH in and stop services
	extra := mergeExtra(p.config.Extra, nil)
	extra["host"] = rec.Host
	if rec.Port > 0 {
		extra["port"] = fmt.Sprintf("%d", rec.Port)
	}

	authMethod, err := resolveAuth(extra)
	if err == nil {
		username := extra["username"]
		if username == "" {
			username = "root"
		}
		sshPort := 22
		if rec.Port > 0 {
			sshPort = rec.Port
		}

		session, err := NewSession(rec.Host, sshPort, username, authMethod)
		if err == nil {
			defer session.Close()
			// Best-effort cleanup on remote server
			cleanupScript := `
docker rm -f ss-server hysteria-server 2>/dev/null || true
systemctl stop vless-server trojan-server 2>/dev/null || true
systemctl disable vless-server trojan-server 2>/dev/null || true
rm -rf /etc/privatedeploy /tmp/privatedeploy 2>/dev/null || true
echo "PrivateDeploy services removed"
`
			session.RunScript(cleanupScript, nil)
		}
	}

	// Remove local record
	delete(records, instanceID)
	return p.saveNodeRecords(records)
}

// GetInstance retrieves a specific SSH node from local records.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	rec, ok := records[instanceID]
	if !ok {
		return nil, cloud.ErrInstanceNotFound
	}
	if ensureManagedTLSDefaults(&rec.InstanceRecord) {
		records[instanceID] = rec
		_ = p.saveNodeRecords(records)
	}

	return &cloud.Instance{
		ID:                 rec.InstanceID,
		Provider:           "ssh",
		Label:              rec.Label,
		Status:             "active",
		IPv4:               rec.IPv4,
		Port:               rec.Port,
		CreatedAt:          parseTime(rec.CreatedAt),
		SSPort:             rec.SSPort,
		SSPassword:         rec.SSPassword,
		HysteriaPort:       rec.HysteriaPort,
		HysteriaPassword:   rec.HysteriaPassword,
		HysteriaServerName: rec.HysteriaServerName,
		HysteriaInsecure:   rec.HysteriaInsecure,
		VLESSPort:          rec.VLESSPort,
		VLESSUUID:          rec.VLESSUUID,
		VLESSPublicKey:     rec.VLESSPublicKey,
		VLESSShortID:       rec.VLESSShortID,
		VLESSServerName:    rec.VLESSServerName,
		TrojanPort:         rec.TrojanPort,
		TrojanPassword:     rec.TrojanPassword,
		TrojanServerName:   rec.TrojanServerName,
		TrojanInsecure:     rec.TrojanInsecure,
	}, nil
}

// TestConnection verifies SSH connectivity with the given config.
func (p *Provider) TestConnection(extra map[string]string) (*ServerInfo, error) {
	host := extra["host"]
	if host == "" {
		return nil, fmt.Errorf("host is required")
	}

	sshPort := 22
	if portStr := extra["port"]; portStr != "" {
		fmt.Sscanf(portStr, "%d", &sshPort)
	}

	username := extra["username"]
	if username == "" {
		username = "root"
	}

	authMethod, err := resolveAuth(extra)
	if err != nil {
		return nil, err
	}

	session, err := NewSession(host, sshPort, username, authMethod)
	if err != nil {
		return nil, err
	}
	defer session.Close()

	if err := session.TestConnection(); err != nil {
		return nil, err
	}

	return session.DetectServer()
}

// --- Persistence helpers ---

func (p *Provider) loadNodeRecords() (map[string]nodeRecord, error) {
	sshNodesMu.Lock()
	defer sshNodesMu.Unlock()

	data, err := os.ReadFile(p.nodesPath)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]nodeRecord{}, nil
	}
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return map[string]nodeRecord{}, nil
	}

	records := map[string]nodeRecord{}
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, err
	}
	return records, nil
}

func (p *Provider) saveNodeRecords(records map[string]nodeRecord) error {
	sshNodesMu.Lock()
	defer sshNodesMu.Unlock()

	if err := os.MkdirAll(filepath.Dir(p.nodesPath), os.ModePerm); err != nil {
		return err
	}

	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(p.nodesPath, data, 0o600)
}

// --- Helpers ---

func mergeExtra(base, override map[string]string) map[string]string {
	result := make(map[string]string)
	for k, v := range base {
		result[k] = v
	}
	for k, v := range override {
		result[k] = v
	}
	return result
}

func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	if record == nil {
		return false
	}

	changed := false

	if record.HysteriaPort != 0 && record.HysteriaPassword != "" {
		if strings.TrimSpace(record.HysteriaServerName) == "" {
			record.HysteriaServerName = deploy.DefaultHysteriaServerName
			changed = true
		}
		if record.HysteriaInsecure == nil {
			record.HysteriaInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.TrojanPort != 0 && record.TrojanPassword != "" {
		if strings.TrimSpace(record.TrojanServerName) == "" {
			record.TrojanServerName = deploy.DefaultTrojanServerName
			changed = true
		}
		if record.TrojanInsecure == nil {
			record.TrojanInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.VLESSPort != 0 && record.VLESSUUID != "" {
		if strings.TrimSpace(record.VLESSServerName) == "" {
			if strings.TrimSpace(record.TrojanServerName) != "" {
				record.VLESSServerName = record.TrojanServerName
			} else {
				record.VLESSServerName = deploy.DefaultVLESSServerName
			}
			changed = true
		}
	}

	return changed
}

func resolveAuth(extra map[string]string) (gossh.AuthMethod, error) {
	method := extra["authMethod"]
	switch method {
	case "key", "privateKey":
		keyData := extra["privateKey"]
		if keyData == "" {
			return nil, fmt.Errorf("private key is required for key authentication")
		}
		return PrivateKeyAuth([]byte(keyData))
	case "password", "":
		password := extra["password"]
		if password == "" {
			return nil, fmt.Errorf("password is required for password authentication")
		}
		return PasswordAuth(password), nil
	default:
		return nil, fmt.Errorf("unsupported auth method: %s", method)
	}
}

func parseTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// progressWriter wraps a buffer and emits progress events for each line of output.
type progressWriter struct {
	buf        *bytes.Buffer
	instanceID string
	emitter    func(string, ...interface{})
}

func (w *progressWriter) Write(p []byte) (int, error) {
	n, err := w.buf.Write(p)
	// Emit last line as progress
	text := string(p)
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > 0 {
		last := lines[len(lines)-1]
		if last != "" && w.emitter != nil {
			w.emitter("cloud:ssh:progress", w.instanceID, "deploying", last)
		}
	}
	return n, err
}
