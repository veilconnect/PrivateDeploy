package gomobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	libbox "github.com/sagernet/sing-box/experimental/libbox"
)

const statusInterval = int64(time.Second)

// Platform exposes the minimal native hooks required to run sing-box through
// Android VpnService or iOS NetworkExtension.
type Platform interface {
	OpenTun(options *TunConfig) (int32, error)
	AutoDetectInterfaceControl(fd int32) error
	WriteLog(message string)
	GetNetworkInterfaces() string
}

// TunConfig is a gomobile-friendly projection of libbox tun options.
// Lists are newline-delimited to keep the Java/Swift bindings simple.
type TunConfig struct {
	inet4AddressList        string
	inet6AddressList        string
	dnsServerAddress        string
	mtu                     int32
	autoRoute               bool
	strictRoute             bool
	routeAddressList        string
	routeExcludeAddressList string
	includePackageList      string
	excludePackageList      string
	httpProxyEnabled        bool
	httpProxyServer         string
	httpProxyServerPort     int32
}

func (c *TunConfig) GetInet4AddressList() string {
	return c.inet4AddressList
}

func (c *TunConfig) GetInet6AddressList() string {
	return c.inet6AddressList
}

func (c *TunConfig) GetDNSServerAddress() string {
	return c.dnsServerAddress
}

func (c *TunConfig) GetMTU() int32 {
	return c.mtu
}

func (c *TunConfig) GetAutoRoute() bool {
	return c.autoRoute
}

func (c *TunConfig) GetStrictRoute() bool {
	return c.strictRoute
}

func (c *TunConfig) GetRouteAddressList() string {
	return c.routeAddressList
}

func (c *TunConfig) GetRouteExcludeAddressList() string {
	return c.routeExcludeAddressList
}

func (c *TunConfig) GetIncludePackageList() string {
	return c.includePackageList
}

func (c *TunConfig) GetExcludePackageList() string {
	return c.excludePackageList
}

func (c *TunConfig) IsHTTPProxyEnabled() bool {
	return c.httpProxyEnabled
}

func (c *TunConfig) GetHTTPProxyServer() string {
	return c.httpProxyServer
}

func (c *TunConfig) GetHTTPProxyServerPort() int32 {
	return c.httpProxyServerPort
}

// VPNService is the gomobile entry point consumed by the Android AAR and the
// iOS framework. It wraps sing-box experimental/libbox so mobile platforms can
// provide the TUN file descriptor while Go owns the VPN runtime lifecycle.
type VPNService struct {
	mu                           sync.RWMutex
	platform                     Platform
	service                      *libbox.BoxService
	commandServer                *libbox.CommandServer
	statusClient                 *libbox.CommandClient
	tracker                      *statusTracker
	configJSON                   string
	basePath                     string
	workingPath                  string
	tempPath                     string
	fixAndroidStack              bool
	underNetworkExtension        bool
	includeAllNetworks           bool
	usePlatformAutoDetectControl bool
	running                      bool
	connectedAt                  int64
	lastError                    string
}

type vpnStatus struct {
	Running     bool   `json:"running"`
	Status      string `json:"status"`
	Message     string `json:"message,omitempty"`
	ConnectedAt int64  `json:"connected_at"`
	Uptime      int64  `json:"uptime"`
}

type vpnStats struct {
	UploadBytes      int64 `json:"upload_bytes"`
	DownloadBytes    int64 `json:"download_bytes"`
	UploadSpeed      int64 `json:"upload_speed"`
	DownloadSpeed    int64 `json:"download_speed"`
	MemoryBytes      int64 `json:"memory_bytes"`
	ConnectionsIn    int32 `json:"connections_in"`
	ConnectionsOut   int32 `json:"connections_out"`
	TrafficAvailable bool  `json:"traffic_available"`
}

func NewVPNService() *VPNService {
	return &VPNService{
		tracker:                      newStatusTracker(),
		fixAndroidStack:              runtime.GOOS == "android",
		usePlatformAutoDetectControl: runtime.GOOS == "android",
	}
}

func (s *VPNService) SetPlatform(platform Platform) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.platform = platform
}

func (s *VPNService) ConfigureRuntime(basePath string, workingPath string, tempPath string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.basePath = strings.TrimSpace(basePath)
	s.workingPath = strings.TrimSpace(workingPath)
	s.tempPath = strings.TrimSpace(tempPath)
}

func (s *VPNService) SetFixAndroidStack(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fixAndroidStack = enabled
}

func (s *VPNService) SetUnderNetworkExtension(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.underNetworkExtension = enabled
	if enabled {
		s.usePlatformAutoDetectControl = false
	}
}

func (s *VPNService) SetIncludeAllNetworks(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.includeAllNetworks = enabled
}

func (s *VPNService) SetUsePlatformAutoDetectInterfaceControl(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usePlatformAutoDetectControl = enabled
}

func (s *VPNService) Start(configJSON string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return errors.New("VPN is already running")
	}
	if strings.TrimSpace(configJSON) == "" {
		return errors.New("VPN config is empty")
	}
	if s.platform == nil {
		return errors.New("platform interface is not configured")
	}

	basePath, workingPath, tempPath, err := s.runtimePathsLocked()
	if err != nil {
		return err
	}
	if err := libbox.Setup(&libbox.SetupOptions{
		BasePath:        basePath,
		WorkingPath:     workingPath,
		TempPath:        tempPath,
		FixAndroidStack: s.fixAndroidStack,
	}); err != nil {
		return fmt.Errorf("setup libbox runtime: %w", err)
	}
	libbox.ClearServiceError()

	if err := libbox.CheckConfig(configJSON); err != nil {
		return fmt.Errorf("validate VPN config: %w", err)
	}

	commandServer := libbox.NewCommandServer(&commandServerHandler{}, 128)
	if err := commandServer.Start(); err != nil {
		return fmt.Errorf("start command server: %w", err)
	}

	service, err := libbox.NewService(configJSON, &platformAdapter{
		platform:                     s.platform,
		underNetworkExtension:        s.underNetworkExtension,
		includeAllNetworks:           s.includeAllNetworks,
		usePlatformAutoDetectControl: s.usePlatformAutoDetectControl,
	})
	if err != nil {
		commandServer.Close()
		return fmt.Errorf("create VPN runtime: %w", err)
	}

	commandServer.SetService(service)
	if err := service.Start(); err != nil {
		service.Close()
		commandServer.Close()
		if serviceError, readErr := libbox.ReadServiceError(); readErr == nil && serviceError != nil && strings.TrimSpace(serviceError.Value) != "" {
			err = fmt.Errorf("%s: %w", serviceError.Value, err)
		}
		return fmt.Errorf("start VPN runtime: %w", err)
	}

	tracker := newStatusTracker()
	statusClient := libbox.NewCommandClient(tracker, &libbox.CommandClientOptions{
		Command:        libbox.CommandStatus,
		StatusInterval: statusInterval,
	})
	if err := statusClient.Connect(); err != nil {
		service.Close()
		commandServer.Close()
		return fmt.Errorf("connect status channel: %w", err)
	}

	s.service = service
	s.commandServer = commandServer
	s.statusClient = statusClient
	s.tracker = tracker
	s.tracker.Reset(time.Now().Unix())
	s.configJSON = configJSON
	s.running = true
	s.connectedAt = time.Now().Unix()
	s.lastError = ""
	return nil
}

func (s *VPNService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return errors.New("VPN is not running")
	}

	err := s.stopLocked()
	s.running = false
	s.connectedAt = 0
	s.lastError = ""
	if s.tracker != nil {
		s.tracker.Clear()
	}
	return err
}

func (s *VPNService) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running
}

func (s *VPNService) GetStats() string {
	s.mu.RLock()
	tracker := s.tracker
	s.mu.RUnlock()

	stats := vpnStats{}
	if tracker != nil {
		stats = tracker.Stats()
	}
	return marshalJSON(stats)
}

func (s *VPNService) UpdateConfig(configJSON string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if strings.TrimSpace(configJSON) == "" {
		return errors.New("VPN config is empty")
	}
	if err := libbox.CheckConfig(configJSON); err != nil {
		return fmt.Errorf("validate VPN config: %w", err)
	}
	s.configJSON = configJSON
	if s.running {
		return errors.New("VPN is running, please restart to apply new config")
	}
	return nil
}

func (s *VPNService) Restart() error {
	s.mu.Lock()
	if strings.TrimSpace(s.configJSON) == "" {
		s.mu.Unlock()
		return errors.New("no config available")
	}
	configJSON := s.configJSON
	if s.running {
		if err := s.stopLocked(); err != nil {
			s.mu.Unlock()
			return err
		}
		s.running = false
		s.connectedAt = 0
	}
	s.mu.Unlock()
	return s.Start(configJSON)
}

func (s *VPNService) GetVersion() string {
	return "PrivateDeploy VPN Core " + libbox.Version()
}

func (s *VPNService) ResetStats() {
	s.mu.RLock()
	tracker := s.tracker
	s.mu.RUnlock()
	if tracker != nil {
		tracker.ResetTotals()
	}
}

func (s *VPNService) GetStatus() string {
	s.mu.RLock()
	running := s.running
	connectedAt := s.connectedAt
	lastError := s.lastError
	tracker := s.tracker
	s.mu.RUnlock()

	status := vpnStatus{
		Running:     running,
		Status:      "disconnected",
		Message:     lastError,
		ConnectedAt: connectedAt,
	}
	if tracker != nil {
		if trackerError := tracker.LastError(); trackerError != "" {
			status.Message = trackerError
		}
	}
	if running {
		status.Status = "connected"
		if connectedAt > 0 {
			status.Uptime = time.Now().Unix() - connectedAt
		}
	} else if status.Message != "" {
		status.Status = "error"
	}
	return marshalJSON(status)
}

func (s *VPNService) stopLocked() error {
	var errs []error
	if s.statusClient != nil {
		if err := s.statusClient.Disconnect(); err != nil {
			errs = append(errs, err)
		}
	}
	if s.service != nil {
		if err := s.service.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	if s.commandServer != nil {
		if err := s.commandServer.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	s.statusClient = nil
	s.service = nil
	s.commandServer = nil
	if len(errs) == 0 {
		return nil
	}
	return errors.Join(errs...)
}

func (s *VPNService) runtimePathsLocked() (string, string, string, error) {
	basePath := strings.TrimSpace(s.basePath)
	if basePath == "" {
		return "", "", "", errors.New("base path is not configured")
	}
	workingPath := strings.TrimSpace(s.workingPath)
	if workingPath == "" {
		workingPath = filepath.Join(basePath, "working")
	}
	tempPath := strings.TrimSpace(s.tempPath)
	if tempPath == "" {
		tempPath = filepath.Join(basePath, "tmp")
	}
	for _, dir := range []string{basePath, workingPath, tempPath} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", "", "", fmt.Errorf("prepare runtime path %s: %w", dir, err)
		}
	}
	return basePath, workingPath, tempPath, nil
}

func marshalJSON(v any) string {
	data, _ := json.Marshal(v)
	return string(data)
}

type statusTracker struct {
	mu           sync.RWMutex
	lastStatus   libbox.StatusMessage
	hasStatus    bool
	baseUpload   int64
	baseDownload int64
	lastError    string
	connectedAt  int64
}

func newStatusTracker() *statusTracker {
	return &statusTracker{}
}

func (t *statusTracker) Connected() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lastError = ""
}

func (t *statusTracker) Disconnected(message string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if message != "" && message != "EOF" {
		t.lastError = message
	}
}

func (t *statusTracker) ClearLogs() {}

func (t *statusTracker) WriteLogs(messageList libbox.StringIterator) {}

func (t *statusTracker) WriteStatus(message *libbox.StatusMessage) {
	if message == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lastStatus = *message
	t.hasStatus = true
}

func (t *statusTracker) InitializeClashMode(modeList libbox.StringIterator, currentMode string) {}

func (t *statusTracker) UpdateClashMode(newMode string) {}

func (t *statusTracker) WriteGroups(message libbox.OutboundGroupIterator) {}

func (t *statusTracker) WriteConnections(message *libbox.Connections) {}

func (t *statusTracker) Reset(connectedAt int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.connectedAt = connectedAt
	t.baseUpload = 0
	t.baseDownload = 0
	t.lastError = ""
}

func (t *statusTracker) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lastStatus = libbox.StatusMessage{}
	t.hasStatus = false
	t.baseUpload = 0
	t.baseDownload = 0
	t.connectedAt = 0
	t.lastError = ""
}

func (t *statusTracker) ResetTotals() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.baseUpload = t.lastStatus.UplinkTotal
	t.baseDownload = t.lastStatus.DownlinkTotal
}

func (t *statusTracker) Stats() vpnStats {
	t.mu.RLock()
	defer t.mu.RUnlock()

	stats := vpnStats{
		MemoryBytes:      t.lastStatus.Memory,
		ConnectionsIn:    t.lastStatus.ConnectionsIn,
		ConnectionsOut:   t.lastStatus.ConnectionsOut,
		TrafficAvailable: t.lastStatus.TrafficAvailable,
	}
	if !t.hasStatus {
		return stats
	}
	stats.UploadBytes = maxInt64(0, t.lastStatus.UplinkTotal-t.baseUpload)
	stats.DownloadBytes = maxInt64(0, t.lastStatus.DownlinkTotal-t.baseDownload)
	stats.UploadSpeed = maxInt64(0, t.lastStatus.Uplink)
	stats.DownloadSpeed = maxInt64(0, t.lastStatus.Downlink)
	return stats
}

func (t *statusTracker) LastError() string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.lastError
}

type commandServerHandler struct{}

func (h *commandServerHandler) ServiceReload() error {
	return nil
}

func (h *commandServerHandler) PostServiceClose() {}

func (h *commandServerHandler) GetSystemProxyStatus() *libbox.SystemProxyStatus {
	return &libbox.SystemProxyStatus{}
}

func (h *commandServerHandler) SetSystemProxyEnabled(isEnabled bool) error {
	return nil
}

type platformAdapter struct {
	platform                     Platform
	underNetworkExtension        bool
	includeAllNetworks           bool
	usePlatformAutoDetectControl bool
	monitorAccess                sync.Mutex
	monitorState                 *defaultInterfaceMonitorState
}

type defaultInterfaceMonitorState struct {
	stop      chan struct{}
	lastName  string
	lastIndex int32
}

type platformNetworkInterfaceSnapshot struct {
	Index       int32    `json:"index"`
	MTU         int32    `json:"mtu"`
	Name        string   `json:"name"`
	Addresses   []string `json:"addresses"`
	Flags       int32    `json:"flags"`
	Type        int32    `json:"type"`
	DNSServers  []string `json:"dns_servers"`
	Metered     bool     `json:"metered"`
	Default     bool     `json:"is_default"`
	Expensive   bool     `json:"expensive"`
	Constrained bool     `json:"constrained"`
}

func (a *platformAdapter) UsePlatformAutoDetectInterfaceControl() bool {
	return a.usePlatformAutoDetectControl
}

func (a *platformAdapter) AutoDetectInterfaceControl(fd int32) error {
	if a.platform == nil {
		return errors.New("platform interface is not configured")
	}
	return a.platform.AutoDetectInterfaceControl(fd)
}

func (a *platformAdapter) OpenTun(options libbox.TunOptions) (int32, error) {
	if a.platform == nil {
		return 0, errors.New("platform interface is not configured")
	}
	return a.platform.OpenTun(newTunConfig(options))
}

func (a *platformAdapter) WriteLog(message string) {
	if a.platform != nil {
		a.platform.WriteLog(message)
	}
}

func (a *platformAdapter) UseProcFS() bool {
	return false
}

func (a *platformAdapter) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (int32, error) {
	return 0, os.ErrInvalid
}

func (a *platformAdapter) PackageNameByUid(uid int32) (string, error) {
	return "", os.ErrInvalid
}

func (a *platformAdapter) UIDByPackageName(packageName string) (int32, error) {
	return -1, os.ErrInvalid
}

func (a *platformAdapter) StartDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	state := &defaultInterfaceMonitorState{
		stop:      make(chan struct{}),
		lastIndex: -1,
	}
	a.monitorAccess.Lock()
	if a.monitorState != nil {
		close(a.monitorState.stop)
	}
	a.monitorState = state
	a.monitorAccess.Unlock()

	go a.runDefaultInterfaceMonitor(listener, state)
	return nil
}

func (a *platformAdapter) CloseDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	a.monitorAccess.Lock()
	defer a.monitorAccess.Unlock()
	if a.monitorState != nil {
		close(a.monitorState.stop)
		a.monitorState = nil
	}
	return nil
}

func (a *platformAdapter) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	platformInterfaces, err := a.platformInterfaces()
	if err != nil {
		return nil, err
	}
	if len(platformInterfaces) > 0 {
		return networkInterfaceIteratorFromSnapshots(platformInterfaces), nil
	}

	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	items := make([]*libbox.NetworkInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		if !isUsableNetworkInterface(iface) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		addresses := make([]string, 0, len(addrs))
		for _, addr := range addrs {
			addresses = append(addresses, addr.String())
		}
		items = append(items, &libbox.NetworkInterface{
			Index:     int32(iface.Index),
			MTU:       int32(iface.MTU),
			Name:      iface.Name,
			Addresses: &stringIterator{values: addresses},
			Flags:     int32(iface.Flags),
			Type:      classifyInterfaceType(iface.Name),
			DNSServer: &stringIterator{},
			Metered:   false,
		})
	}
	return &networkInterfaceIterator{values: items}, nil
}

func (a *platformAdapter) UnderNetworkExtension() bool {
	return a.underNetworkExtension
}

func (a *platformAdapter) IncludeAllNetworks() bool {
	return a.includeAllNetworks
}

func (a *platformAdapter) ReadWIFIState() *libbox.WIFIState {
	return nil
}

func (a *platformAdapter) ClearDNSCache() {}

func (a *platformAdapter) SendNotification(notification *libbox.Notification) error {
	return nil
}

func (a *platformAdapter) runDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener, state *defaultInterfaceMonitorState) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		if !a.updateDefaultInterface(listener, state) {
			return
		}
		select {
		case <-state.stop:
			return
		case <-ticker.C:
		}
	}
}

func (a *platformAdapter) updateDefaultInterface(listener libbox.InterfaceUpdateListener, state *defaultInterfaceMonitorState) bool {
	platformInterfaces, err := a.platformInterfaces()
	if err != nil {
		a.WriteLog("failed to enumerate platform interfaces: " + err.Error())
		return true
	}
	if len(platformInterfaces) > 0 {
		defaultInterface := selectDefaultPlatformInterface(platformInterfaces)
		if defaultInterface == nil {
			if state.lastIndex != -1 {
				state.lastName = ""
				state.lastIndex = -1
				listener.UpdateDefaultInterface("", -1, false, false)
			}
			return true
		}
		if state.lastIndex == defaultInterface.Index && state.lastName == defaultInterface.Name {
			return true
		}

		state.lastName = defaultInterface.Name
		state.lastIndex = defaultInterface.Index
		listener.UpdateDefaultInterface(defaultInterface.Name, defaultInterface.Index, defaultInterface.Expensive, defaultInterface.Constrained)
		return true
	}

	interfaces, err := net.Interfaces()
	if err != nil {
		a.WriteLog("failed to enumerate interfaces: " + err.Error())
		return true
	}

	defaultInterface := selectDefaultInterface(interfaces)
	if defaultInterface == nil {
		if state.lastIndex != -1 {
			state.lastName = ""
			state.lastIndex = -1
			listener.UpdateDefaultInterface("", -1, false, false)
		}
		return true
	}
	if state.lastIndex == int32(defaultInterface.Index) && state.lastName == defaultInterface.Name {
		return true
	}

	state.lastName = defaultInterface.Name
	state.lastIndex = int32(defaultInterface.Index)
	listener.UpdateDefaultInterface(defaultInterface.Name, int32(defaultInterface.Index), false, false)
	return true
}

func (a *platformAdapter) platformInterfaces() ([]platformNetworkInterfaceSnapshot, error) {
	if a.platform == nil {
		return nil, nil
	}
	rawInterfaces := strings.TrimSpace(a.platform.GetNetworkInterfaces())
	if rawInterfaces == "" {
		return nil, nil
	}

	var interfaces []platformNetworkInterfaceSnapshot
	if err := json.Unmarshal([]byte(rawInterfaces), &interfaces); err != nil {
		return nil, fmt.Errorf("decode platform interfaces: %w", err)
	}
	return interfaces, nil
}

func selectDefaultInterface(interfaces []net.Interface) *net.Interface {
	var (
		best      *net.Interface
		bestScore = -1
	)
	for i := range interfaces {
		iface := interfaces[i]
		if !isUsableNetworkInterface(iface) {
			continue
		}
		score := interfacePriority(iface.Name)
		if iface.Flags&net.FlagRunning != 0 {
			score += 10
		}
		if score > bestScore {
			candidate := iface
			best = &candidate
			bestScore = score
		}
	}
	return best
}

func selectDefaultPlatformInterface(interfaces []platformNetworkInterfaceSnapshot) *platformNetworkInterfaceSnapshot {
	var (
		best      *platformNetworkInterfaceSnapshot
		bestScore = -1
	)
	for i := range interfaces {
		iface := interfaces[i]
		if strings.TrimSpace(iface.Name) == "" {
			continue
		}

		score := interfacePriority(iface.Name)
		switch iface.Type {
		case libbox.InterfaceTypeWIFI:
			score += 30
		case libbox.InterfaceTypeCellular:
			score += 20
		case libbox.InterfaceTypeEthernet:
			score += 10
		}
		if iface.Default {
			score += 1000
		}
		if iface.Expensive || iface.Metered {
			score -= 25
		}
		if iface.Constrained {
			score -= 25
		}
		if score > bestScore {
			candidate := iface
			best = &candidate
			bestScore = score
		}
	}
	return best
}

func isUsableNetworkInterface(iface net.Interface) bool {
	if iface.Flags&net.FlagUp == 0 {
		return false
	}
	if iface.Flags&net.FlagLoopback != 0 {
		return false
	}
	name := strings.ToLower(strings.TrimSpace(iface.Name))
	if name == "" {
		return false
	}
	for _, prefix := range []string{"lo", "tun", "utun", "tap", "ipsec", "ppp"} {
		if strings.HasPrefix(name, prefix) {
			return false
		}
	}
	return true
}

func classifyInterfaceType(name string) int32 {
	switch {
	case isWiFiInterface(name):
		return libbox.InterfaceTypeWIFI
	case isCellularInterface(name):
		return libbox.InterfaceTypeCellular
	case isEthernetInterface(name):
		return libbox.InterfaceTypeEthernet
	default:
		return libbox.InterfaceTypeOther
	}
}

func interfacePriority(name string) int {
	switch {
	case isWiFiInterface(name):
		return 300
	case isCellularInterface(name):
		return 250
	case isEthernetInterface(name):
		return 200
	default:
		return 100
	}
}

func isWiFiInterface(name string) bool {
	lowerName := strings.ToLower(strings.TrimSpace(name))
	return strings.HasPrefix(lowerName, "wlan") ||
		strings.HasPrefix(lowerName, "wifi") ||
		strings.HasPrefix(lowerName, "swlan") ||
		strings.HasPrefix(lowerName, "ap")
}

func isCellularInterface(name string) bool {
	lowerName := strings.ToLower(strings.TrimSpace(name))
	return strings.HasPrefix(lowerName, "rmnet") ||
		strings.HasPrefix(lowerName, "ccmni") ||
		strings.HasPrefix(lowerName, "pdp") ||
		strings.HasPrefix(lowerName, "wwan") ||
		strings.HasPrefix(lowerName, "cell")
}

func isEthernetInterface(name string) bool {
	lowerName := strings.ToLower(strings.TrimSpace(name))
	return strings.HasPrefix(lowerName, "eth") ||
		strings.HasPrefix(lowerName, "en")
}

func newTunConfig(options libbox.TunOptions) *TunConfig {
	config := &TunConfig{
		mtu:                     options.GetMTU(),
		autoRoute:               options.GetAutoRoute(),
		strictRoute:             options.GetStrictRoute(),
		inet4AddressList:        routePrefixIteratorString(options.GetInet4Address()),
		inet6AddressList:        routePrefixIteratorString(options.GetInet6Address()),
		routeAddressList:        routePrefixIteratorString(mergeRouteIterators(options.GetInet4RouteRange(), options.GetInet6RouteRange(), options.GetInet4RouteAddress(), options.GetInet6RouteAddress())...),
		routeExcludeAddressList: routePrefixIteratorString(mergeRouteIterators(options.GetInet4RouteExcludeAddress(), options.GetInet6RouteExcludeAddress())...),
		includePackageList:      stringIteratorString(options.GetIncludePackage()),
		excludePackageList:      stringIteratorString(options.GetExcludePackage()),
	}
	applyHTTPProxyConfig(config, options)
	if dnsServer, err := options.GetDNSServerAddress(); err == nil && dnsServer != nil {
		config.dnsServerAddress = dnsServer.Value
	}
	return config
}

type httpProxyOptions interface {
	IsHTTPProxyEnabled() bool
	GetHTTPProxyServer() string
	GetHTTPProxyServerPort() int32
}

func applyHTTPProxyConfig(config *TunConfig, options httpProxyOptions) {
	if !options.IsHTTPProxyEnabled() {
		return
	}
	config.httpProxyEnabled = true
	config.httpProxyServer = options.GetHTTPProxyServer()
	config.httpProxyServerPort = options.GetHTTPProxyServerPort()
}

func routePrefixIteratorString(iterators ...libbox.RoutePrefixIterator) string {
	values := make([]string, 0)
	for _, iterator := range iterators {
		for iterator != nil && iterator.HasNext() {
			prefix := iterator.Next()
			if prefix != nil {
				values = append(values, prefix.String())
			}
		}
	}
	return strings.Join(values, "\n")
}

func stringIteratorString(iterator libbox.StringIterator) string {
	values := make([]string, 0)
	for iterator != nil && iterator.HasNext() {
		values = append(values, iterator.Next())
	}
	return strings.Join(values, "\n")
}

func mergeRouteIterators(iterators ...libbox.RoutePrefixIterator) []libbox.RoutePrefixIterator {
	return iterators
}

type stringIterator struct {
	values []string
}

func (i *stringIterator) Len() int32 {
	return int32(len(i.values))
}

func (i *stringIterator) HasNext() bool {
	return len(i.values) > 0
}

func (i *stringIterator) Next() string {
	if len(i.values) == 0 {
		return ""
	}
	next := i.values[0]
	i.values = i.values[1:]
	return next
}

type networkInterfaceIterator struct {
	values []*libbox.NetworkInterface
}

func networkInterfaceIteratorFromSnapshots(interfaces []platformNetworkInterfaceSnapshot) *networkInterfaceIterator {
	items := make([]*libbox.NetworkInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		if strings.TrimSpace(iface.Name) == "" {
			continue
		}
		items = append(items, &libbox.NetworkInterface{
			Index:     iface.Index,
			MTU:       iface.MTU,
			Name:      iface.Name,
			Addresses: &stringIterator{values: append([]string(nil), iface.Addresses...)},
			Flags:     iface.Flags,
			Type:      iface.Type,
			DNSServer: &stringIterator{values: append([]string(nil), iface.DNSServers...)},
			Metered:   iface.Metered,
		})
	}
	return &networkInterfaceIterator{values: items}
}

func (i *networkInterfaceIterator) HasNext() bool {
	return len(i.values) > 0
}

func (i *networkInterfaceIterator) Next() *libbox.NetworkInterface {
	if len(i.values) == 0 {
		return nil
	}
	next := i.values[0]
	i.values = i.values[1:]
	return next
}

func maxInt64(a int64, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
