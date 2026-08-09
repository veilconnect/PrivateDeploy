package ssh

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/persistence"
	"privatedeploy/bridge/cloud/providers/internal/provutil"

	gossh "golang.org/x/crypto/ssh"
)

const (
	configFileRelPath = "data/cloud/ssh-config.json"
	nodesFileRelPath  = "data/cloud/ssh-nodes.json"
)

var sshNodesMu sync.Mutex
var sshAuthMu sync.Mutex

const sshInstanceAuthScopePrefix = "ssh-instance-auth:"
const sshProviderAuthScope = "ssh-provider-auth"

var sshSensitiveExtraKeys = map[string]struct{}{
	"password":   {},
	"privateKey": {},
	"passphrase": {},
}

// nodeRecord stores SSH node data for JSON persistence.
type nodeRecord struct {
	cloud.InstanceRecord
	InstanceID string `json:"instanceId"`
	Label      string `json:"label"`
	Host       string `json:"host"`
}

// storedInstanceAuth is serialized only through cloud.SaveSecret. It never
// enters provider config JSON or the encrypted node-record bundle.
type storedInstanceAuth struct {
	Username   string `json:"username,omitempty"`
	AuthMethod string `json:"authMethod,omitempty"`
	Password   string `json:"password,omitempty"`
	PrivateKey string `json:"privateKey,omitempty"`
	Passphrase string `json:"passphrase,omitempty"`
}

// Provider implements cloud.CloudProvider for SSH-based deployment.
type Provider struct {
	configMu   sync.RWMutex
	config     *cloud.ProviderConfig
	configPath string
	nodesPath  string

	// eventEmitter is called with (eventName, data...) to push progress events.
	// Set by the bridge layer via SetEventEmitter.
	eventEmitterMu sync.RWMutex
	eventEmitter   func(eventName string, data ...interface{})
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
		config:     cloneProviderConfig(config),
		configPath: filepath.Join(basePath, configFileRelPath),
		nodesPath:  filepath.Join(basePath, nodesFileRelPath),
	}
}

// SetEventEmitter sets the callback used to push Wails events.
func (p *Provider) SetEventEmitter(fn func(eventName string, data ...interface{})) {
	p.eventEmitterMu.Lock()
	defer p.eventEmitterMu.Unlock()
	p.eventEmitter = fn
}

func (p *Provider) emit(event string, data ...interface{}) {
	p.eventEmitterMu.RLock()
	emitter := p.eventEmitter
	p.eventEmitterMu.RUnlock()
	if emitter != nil {
		emitter(event, data...)
	}
}

// Name returns the provider identifier.
func (p *Provider) Name() string { return "ssh" }

// DisplayName returns the human-readable provider name.
func (p *Provider) DisplayName() string { return "SSH Server" }

// LoadConfig loads the SSH configuration from file.
func (p *Provider) LoadConfig() (*cloud.ProviderConfig, error) {
	p.configMu.Lock()
	defer p.configMu.Unlock()

	data, err := os.ReadFile(p.configPath)
	if errors.Is(err, os.ErrNotExist) {
		p.config = &cloud.ProviderConfig{Provider: "ssh"}
		return cloneProviderConfig(p.config), nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	if len(data) == 0 {
		p.config = &cloud.ProviderConfig{Provider: "ssh"}
		return cloneProviderConfig(p.config), nil
	}

	var cfg cloud.ProviderConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	if cfg.Provider == "" {
		cfg.Provider = "ssh"
	}
	if sanitizedExtra, changed := sanitizeSSHConfigExtra(cfg.Extra); changed {
		if err := p.saveAuth(sshProviderAuthScope, cfg.Extra); err != nil {
			return nil, fmt.Errorf("failed to migrate SSH credentials to secure storage: %w", err)
		}
		cfg.Extra = sanitizedExtra
		if err := p.writeConfig(&cfg); err != nil {
			return nil, err
		}
	}

	p.config = cloneProviderConfig(&cfg)
	return cloneProviderConfig(p.config), nil
}

// SaveConfig persists the SSH configuration to file.
func (p *Provider) SaveConfig(config *cloud.ProviderConfig) error {
	if config == nil {
		return cloud.ErrInvalidConfig
	}
	config = cloneProviderConfig(config)

	p.configMu.Lock()
	defer p.configMu.Unlock()

	if config.Provider != "ssh" {
		return fmt.Errorf("invalid provider: expected ssh, got %s", config.Provider)
	}
	if hasSSHAuthMaterial(config.Extra) {
		if err := p.saveAuth(sshProviderAuthScope, config.Extra); err != nil {
			return fmt.Errorf("failed to store SSH credentials securely: %w", err)
		}
	}

	sanitized := *config
	sanitized.Extra, _ = sanitizeSSHConfigExtra(config.Extra)
	if err := p.writeConfig(&sanitized); err != nil {
		return err
	}

	p.config = cloneProviderConfig(&sanitized)
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
	var instances []cloud.Instance
	err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		dirty := false
		instances = make([]cloud.Instance, 0, len(records))
		for id, rec := range records {
			if ensureManagedTLSDefaults(&rec.InstanceRecord) {
				records[id] = rec
				dirty = true
			}
			instances = append(instances, instanceFromRecord(rec))
		}
		return dirty, nil
	})
	if err != nil {
		return nil, err
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

	// Merge SSH connection params with an explicit precedence contract:
	// opts.Extra.host > opts.Host > saved provider config Extra.host. Host is a
	// first-class CreateInstanceOptions field and must not be silently ignored
	// by the public API merely because legacy callers used extra.host.
	extra, err := p.mergedCreateExtra(opts)
	if err != nil {
		return nil, err
	}
	tuning := deploy.ResolveDeploymentTuning(extra)
	tuning.VLESSServerName = deploy.SelectVLESSRealityTarget(ctx, tuning.VLESSServerName)

	host := extra["host"]
	if host == "" {
		return nil, fmt.Errorf("SSH host is required (set host or extra.host)")
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

	instanceID, err := newInstanceID(host)
	if err != nil {
		return nil, fmt.Errorf("failed to generate SSH instance ID: %w", err)
	}

	// 1. Connect
	p.emit("cloud:ssh:progress", instanceID, "connecting", "正在连接到服务器...")
	log.Printf("[SSHProvider] Connecting to %s:%d as %s", host, sshPort, username)

	session, err := NewSessionContext(ctx, host, sshPort, username, authMethod)
	if err != nil {
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("连接失败: %v", err))
		return nil, fmt.Errorf("SSH connection failed: %w", err)
	}
	defer session.Close()

	// 2. Detect server environment
	p.emit("cloud:ssh:progress", instanceID, "detecting", "正在检测服务器环境...")
	info, err := session.DetectServerContext(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to detect SSH server: %w", err)
	}
	log.Printf("[SSHProvider] Server: OS=%s Arch=%s RAM=%dMB", info.OS, info.Arch, info.Memory)

	// 3. Generate credentials
	p.emit("cloud:ssh:progress", instanceID, "generating", "正在生成部署参数...")

	ports := deploy.AllocatePorts(tuning.PortProfile)
	ssPort := ports.SSPort
	hysteriaPort := ports.HysteriaPort
	vlessPort := ports.VLESSPort
	trojanPort := ports.TrojanPort
	vlessRelayPort := ports.VLESSRelayPort

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
	realityShortID := provutil.GenerateShortID()

	// 4. Generate and execute deployment script
	var script string
	if info.Memory > 0 && info.Memory <= 600 {
		p.emit("cloud:ssh:progress", instanceID, "deploying", "Low memory; deploying lightweight mode (Shadowsocks only)...")
		script = deploy.GenerateLightweightScript(ssPort, ssPassword, sshPort)
	} else {
		p.emit("cloud:ssh:progress", instanceID, "deploying", "Deploying multi-protocol proxy (SS + Hysteria2 + VLESS + Trojan)...")
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
			VLESSRelayPort:   vlessRelayPort,
			SingBoxVersion:   tuning.SingBoxVersion,
			SingBoxFallback:  tuning.SingBoxFallbackVersion,
			SSHPort:          sshPort,
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
	if err := session.RunScriptContext(ctx, script, progressWriter); err != nil {
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("部署脚本执行失败: %v", err))
		return nil, fmt.Errorf("deployment script failed: %w\noutput:\n%s", err, outputBuf.String())
	}

	// 5. Verify ports
	p.emit("cloud:ssh:progress", instanceID, "verifying", "正在验证端口...")
	expectedTCPPorts := []int{ssPort}
	expectedUDPPorts := []int{ssPort}
	isMulti := info.Memory == 0 || info.Memory > 600
	if isMulti {
		expectedTCPPorts = append(expectedTCPPorts, vlessPort, trojanPort)
		expectedUDPPorts = append(expectedUDPPorts, hysteriaPort)
	}

	// Poll for ports to come up (max 60 seconds)
	allOpen := false
	for attempt := 0; attempt < 6; attempt++ {
		tcpOpen, tcpErr := session.CheckTCPPortsContext(ctx, expectedTCPPorts)
		udpOpen, udpErr := session.CheckUDPPortsContext(ctx, expectedUDPPorts)
		if tcpErr != nil || udpErr != nil {
			return nil, fmt.Errorf("failed to verify deployed service ports (tcp=%v, udp=%v)", tcpErr, udpErr)
		}
		allOpen = true
		for _, open := range tcpOpen {
			if !open {
				allOpen = false
				break
			}
		}
		for _, open := range udpOpen {
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
	if !allOpen {
		return nil, fmt.Errorf("deployment completed but required TCP/UDP service ports did not become ready")
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
		instance.VLESSRelayPort = vlessRelayPort
	}

	// Persist node record
	record := nodeRecord{
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
			VLESSRelayPort:     instance.VLESSRelayPort,
		},
	}
	if err := p.saveInstanceAuth(instanceID, extra); err != nil {
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("保存 SSH 凭据失败: %v", err))
		return nil, fmt.Errorf(
			"deployment completed on %s but secure SSH credential persistence failed; inspect the remote server manually: %w",
			host,
			err,
		)
	}
	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if _, exists := records[instanceID]; exists {
			return false, fmt.Errorf("SSH instance ID collision: %s", instanceID)
		}
		records[instanceID] = record
		return true, nil
	}); err != nil {
		credentialCleanupErr := p.deleteInstanceAuth(instanceID)
		p.emit("cloud:ssh:progress", instanceID, "failed", fmt.Sprintf("保存节点记录失败: %v", err))
		if credentialCleanupErr != nil {
			return nil, fmt.Errorf(
				"failed to save SSH node record: %w (credential cleanup also failed: %v)",
				err,
				credentialCleanupErr,
			)
		}
		return nil, fmt.Errorf("failed to save SSH node record: %w", err)
	}

	p.emit("cloud:ssh:progress", instanceID, "ready", "部署完成！")
	log.Printf("[SSHProvider] Deployment complete for %s (ID: %s)", host, instanceID)
	return instance, nil
}

func (p *Provider) mergedCreateExtra(opts *cloud.CreateInstanceOptions) (map[string]string, error) {
	extra := p.configSnapshot().Extra
	storedAuth, err := p.loadAuth(sshProviderAuthScope)
	if err == nil {
		extra = provutil.MergeExtra(extra, storedAuth)
	} else if !errors.Is(err, cloud.ErrSecretNotFound) {
		return nil, fmt.Errorf("failed to load stored SSH credentials: %w", err)
	}
	extra = provutil.MergeExtra(extra, opts.Extra)
	if _, explicitlySet := opts.Extra["host"]; !explicitlySet && strings.TrimSpace(opts.Host) != "" {
		extra["host"] = strings.TrimSpace(opts.Host)
	}
	return extra, nil
}

// RepairInstance re-runs the deployment script on the same SSH host and keeps
// the original PrivateDeploy node ID so saved profiles continue to target it.
func (p *Provider) RepairInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" || instanceID != strings.TrimSpace(instanceID) {
		return nil, cloud.ErrInstanceNotFound
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	previous, ok := records[instanceID]
	if !ok {
		return nil, cloud.ErrInstanceNotFound
	}

	host := previous.Host
	if host == "" {
		host = previous.IPv4
	}
	if host == "" {
		return nil, fmt.Errorf("SSH host is missing for node %s", instanceID)
	}

	extra := map[string]string{
		"host": host,
	}
	if previous.Port > 0 {
		extra["port"] = fmt.Sprintf("%d", previous.Port)
	}
	authExtra, err := p.loadInstanceAuth(instanceID)
	if err != nil {
		return nil, fmt.Errorf("SSH credentials unavailable for repair of %s: %w", instanceID, err)
	}
	for key, value := range authExtra {
		extra[key] = value
	}

	deployed, err := p.CreateInstance(ctx, &cloud.CreateInstanceOptions{
		Label: previous.Label,
		Extra: extra,
	})
	if err != nil {
		return nil, err
	}

	var repaired nodeRecord
	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		var ok bool
		repaired, ok = records[deployed.ID]
		if !ok {
			return false, fmt.Errorf("repaired SSH node record was not saved")
		}
		delete(records, deployed.ID)
		repaired.InstanceID = instanceID
		repaired.Label = previous.Label
		repaired.Host = host
		if previous.CreatedAt != "" {
			repaired.CreatedAt = previous.CreatedAt
		}
		records[instanceID] = repaired
		return true, nil
	}); err != nil {
		return nil, err
	}
	// CreateInstance stored the same credentials under its temporary ID. The
	// original ID retains the pre-existing credential entry used above.
	if err := p.deleteInstanceAuth(deployed.ID); err != nil {
		return nil, fmt.Errorf("SSH node repaired but temporary credential cleanup failed: %w", err)
	}

	deployed.ID = instanceID
	deployed.Label = previous.Label
	deployed.CreatedAt = parseTime(repaired.CreatedAt)
	return deployed, nil
}

// DestroyInstance SSH-connects to stop services, then removes the local record.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if instanceID == "" || instanceID != strings.TrimSpace(instanceID) {
		return cloud.ErrInstanceNotFound
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return err
	}

	rec, ok := records[instanceID]
	if !ok {
		return cloud.ErrInstanceNotFound
	}

	// SSH credentials are intentionally stored outside config/node JSON. Never
	// silently forget the node if credentials are missing or remote cleanup
	// fails: the caller must see a failed operation and retain a retry path.
	extra, err := p.loadInstanceAuth(instanceID)
	if err != nil {
		return fmt.Errorf("SSH credentials unavailable for destroy of %s: %w", instanceID, err)
	}
	extra["host"] = rec.Host
	if rec.Port > 0 {
		extra["port"] = fmt.Sprintf("%d", rec.Port)
	}

	authMethod, err := resolveAuth(extra)
	if err != nil {
		return fmt.Errorf("invalid stored SSH credentials for %s: %w", instanceID, err)
	}
	username := extra["username"]
	if username == "" {
		username = "root"
	}
	sshPort := 22
	if rec.Port > 0 {
		sshPort = rec.Port
	}

	session, err := NewSessionContext(ctx, rec.Host, sshPort, username, authMethod)
	if err != nil {
		return fmt.Errorf("failed to connect for SSH destroy of %s: %w", instanceID, err)
	}
	defer session.Close()
	cleanupScript := `
docker rm -f ss-server hysteria-server 2>/dev/null || true
systemctl stop hysteria-server vless-server trojan-server 2>/dev/null || true
systemctl disable hysteria-server vless-server trojan-server 2>/dev/null || true
rm -rf /etc/privatedeploy /tmp/privatedeploy 2>/dev/null || true
echo "PrivateDeploy services removed"
`
	if err := session.RunScriptContext(ctx, cleanupScript, nil); err != nil {
		return fmt.Errorf("remote SSH cleanup failed for %s: %w", instanceID, err)
	}

	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if _, ok := records[instanceID]; !ok {
			return false, cloud.ErrInstanceNotFound
		}
		delete(records, instanceID)
		return true, nil
	}); err != nil {
		return err
	}
	if err := p.deleteInstanceAuth(instanceID); err != nil {
		return fmt.Errorf("remote SSH cleanup and local record removal succeeded, but credential cleanup failed: %w", err)
	}
	return nil
}

// GetInstance retrieves a specific SSH node from local records.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	var instance cloud.Instance
	err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		rec, ok := records[instanceID]
		if !ok {
			return false, cloud.ErrInstanceNotFound
		}
		dirty := ensureManagedTLSDefaults(&rec.InstanceRecord)
		if dirty {
			records[instanceID] = rec
		}
		instance = instanceFromRecord(rec)
		return dirty, nil
	})
	if err != nil {
		return nil, err
	}
	return &instance, nil
}

func instanceFromRecord(rec nodeRecord) cloud.Instance {
	return cloud.Instance{
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
		VLESSRelayPort:     rec.VLESSRelayPort,
	}
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

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	session, err := NewSessionContext(ctx, host, sshPort, username, authMethod)
	if err != nil {
		return nil, err
	}
	defer session.Close()

	if _, err := session.RunCommandContext(ctx, "echo ok"); err != nil {
		return nil, err
	}

	return session.DetectServerContext(ctx)
}

// --- Persistence helpers ---

// loadNodeRecordsLocked reads the records file. Callers must hold sshNodesMu.
func (p *Provider) loadNodeRecordsLocked() (map[string]nodeRecord, error) {
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
	if err := cloud.DecodeRecords(data, &records); err != nil {
		return nil, err
	}
	return records, nil
}

// saveNodeRecordsLocked writes the records file. Callers must hold sshNodesMu.
func (p *Provider) saveNodeRecordsLocked(records map[string]nodeRecord) error {
	if err := os.MkdirAll(filepath.Dir(p.nodesPath), 0o750); err != nil {
		return err
	}

	data, err := cloud.EncodeRecords(records)
	if err != nil {
		return err
	}

	return persistence.WritePrivateFileAtomic(p.nodesPath, data)
}

// loadNodeRecords returns a read-only snapshot. Mutations must use
// mutateNodeRecords so a concurrent writer cannot be overwritten.
func (p *Provider) loadNodeRecords() (map[string]nodeRecord, error) {
	sshNodesMu.Lock()
	defer sshNodesMu.Unlock()
	return p.loadNodeRecordsLocked()
}

// mutateNodeRecords holds sshNodesMu for the complete load -> mutate -> save
// cycle. If loading fails, the callback is never invoked and the existing file
// is never overwritten (fail closed).
func (p *Provider) mutateNodeRecords(mutate func(records map[string]nodeRecord) (save bool, err error)) error {
	sshNodesMu.Lock()
	defer sshNodesMu.Unlock()

	records, err := p.loadNodeRecordsLocked()
	if err != nil {
		return err
	}

	save, err := mutate(records)
	if err != nil {
		return err
	}
	if !save {
		return nil
	}

	return p.saveNodeRecordsLocked(records)
}

func (p *Provider) writeConfig(config *cloud.ProviderConfig) error {
	if err := os.MkdirAll(filepath.Dir(p.configPath), 0o750); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := persistence.WritePrivateFileAtomic(p.configPath, data); err != nil {
		return fmt.Errorf("failed to write config: %w", err)
	}
	return nil
}

// --- Helpers ---

func sanitizeSSHConfigExtra(extra map[string]string) (map[string]string, bool) {
	if len(extra) == 0 {
		return map[string]string{}, false
	}

	sanitized := make(map[string]string, len(extra))
	changed := false
	for key, value := range extra {
		if _, sensitive := sshSensitiveExtraKeys[key]; sensitive {
			if strings.TrimSpace(value) != "" {
				changed = true
			}
			continue
		}
		sanitized[key] = value
	}
	return sanitized, changed
}

func cloneProviderConfig(config *cloud.ProviderConfig) *cloud.ProviderConfig {
	if config == nil {
		return nil
	}
	clone := *config
	if config.Extra != nil {
		clone.Extra = make(map[string]string, len(config.Extra))
		for key, value := range config.Extra {
			clone.Extra[key] = value
		}
	}
	return &clone
}

func (p *Provider) configSnapshot() *cloud.ProviderConfig {
	p.configMu.RLock()
	defer p.configMu.RUnlock()
	return cloneProviderConfig(p.config)
}

func (p *Provider) saveInstanceAuth(instanceID string, extra map[string]string) error {
	return p.saveAuth(sshInstanceAuthScopePrefix+instanceID, extra)
}

func (p *Provider) saveAuth(scope string, extra map[string]string) error {
	auth := storedInstanceAuth{
		Username:   extra["username"],
		AuthMethod: extra["authMethod"],
		Password:   extra["password"],
		PrivateKey: extra["privateKey"],
		Passphrase: extra["passphrase"],
	}
	payload, err := json.Marshal(auth)
	if err != nil {
		return fmt.Errorf("encode SSH credentials: %w", err)
	}
	sshAuthMu.Lock()
	defer sshAuthMu.Unlock()
	return cloud.SaveSecret(p.configPath, scope, string(payload))
}

func (p *Provider) loadInstanceAuth(instanceID string) (map[string]string, error) {
	return p.loadAuth(sshInstanceAuthScopePrefix + instanceID)
}

func (p *Provider) loadAuth(scope string) (map[string]string, error) {
	sshAuthMu.Lock()
	payload, err := cloud.LoadSecret(p.configPath, scope)
	sshAuthMu.Unlock()
	if err != nil {
		return nil, err
	}
	var auth storedInstanceAuth
	if err := json.Unmarshal([]byte(payload), &auth); err != nil {
		return nil, fmt.Errorf("decode stored SSH credentials: %w", err)
	}
	return map[string]string{
		"username":   auth.Username,
		"authMethod": auth.AuthMethod,
		"password":   auth.Password,
		"privateKey": auth.PrivateKey,
		"passphrase": auth.Passphrase,
	}, nil
}

func (p *Provider) deleteInstanceAuth(instanceID string) error {
	sshAuthMu.Lock()
	defer sshAuthMu.Unlock()
	return cloud.DeleteSecret(p.configPath, sshInstanceAuthScopePrefix+instanceID)
}

func hasSSHAuthMaterial(extra map[string]string) bool {
	return strings.TrimSpace(extra["password"]) != "" || strings.TrimSpace(extra["privateKey"]) != ""
}

func newInstanceID(host string) (string, error) {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	hostPart := strings.NewReplacer(".", "-", ":", "-").Replace(host)
	return fmt.Sprintf("cloud-ssh-%s-%d-%x", hostPart, time.Now().UnixNano(), random), nil
}

// ensureManagedTLSDefaults delegates to the shared cloud implementation so the
// managed-protocol TLS defaults stay identical across every provider.
func ensureManagedTLSDefaults(record *cloud.InstanceRecord) bool {
	return cloud.EnsureManagedTLSDefaults(record)
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
