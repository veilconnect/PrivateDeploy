package gomobile

import (
	"net"
	"testing"

	libbox "github.com/sagernet/sing-box/experimental/libbox"
)

type fakePlatform struct {
	networkInterfaces string
}

func (p fakePlatform) OpenTun(options *TunConfig) (int32, error) {
	return 0, nil
}

func (p fakePlatform) AutoDetectInterfaceControl(fd int32) error {
	return nil
}

func (p fakePlatform) WriteLog(message string) {}

func (p fakePlatform) GetNetworkInterfaces() string {
	return p.networkInterfaces
}

type fakeHTTPProxyOptions struct {
	enabled     bool
	server      string
	port        int32
	panicOnRead bool
}

func (o fakeHTTPProxyOptions) IsHTTPProxyEnabled() bool {
	return o.enabled
}

func (o fakeHTTPProxyOptions) GetHTTPProxyServer() string {
	if o.panicOnRead {
		panic("unexpected GetHTTPProxyServer call")
	}
	return o.server
}

func (o fakeHTTPProxyOptions) GetHTTPProxyServerPort() int32 {
	if o.panicOnRead {
		panic("unexpected GetHTTPProxyServerPort call")
	}
	return o.port
}

func TestApplyHTTPProxyConfigSkipsDisabledProxy(t *testing.T) {
	config := &TunConfig{}

	applyHTTPProxyConfig(config, fakeHTTPProxyOptions{
		enabled:     false,
		panicOnRead: true,
	})

	if config.httpProxyEnabled {
		t.Fatal("expected HTTP proxy to remain disabled")
	}
	if config.httpProxyServer != "" {
		t.Fatalf("expected empty HTTP proxy server, got %q", config.httpProxyServer)
	}
	if config.httpProxyServerPort != 0 {
		t.Fatalf("expected empty HTTP proxy port, got %d", config.httpProxyServerPort)
	}
}

func TestApplyHTTPProxyConfigCopiesEnabledProxy(t *testing.T) {
	config := &TunConfig{}

	applyHTTPProxyConfig(config, fakeHTTPProxyOptions{
		enabled: true,
		server:  "127.0.0.1",
		port:    8080,
	})

	if !config.httpProxyEnabled {
		t.Fatal("expected HTTP proxy to be enabled")
	}
	if config.httpProxyServer != "127.0.0.1" {
		t.Fatalf("unexpected HTTP proxy server %q", config.httpProxyServer)
	}
	if config.httpProxyServerPort != 8080 {
		t.Fatalf("unexpected HTTP proxy port %d", config.httpProxyServerPort)
	}
}

func TestSelectDefaultInterfacePrefersWiFi(t *testing.T) {
	interfaces := []net.Interface{
		{Name: "rmnet_data0", Index: 5, Flags: net.FlagUp | net.FlagRunning},
		{Name: "wlan0", Index: 7, Flags: net.FlagUp | net.FlagRunning},
		{Name: "tun0", Index: 9, Flags: net.FlagUp | net.FlagRunning},
	}

	selected := selectDefaultInterface(interfaces)
	if selected == nil {
		t.Fatal("expected a default interface")
	}
	if selected.Name != "wlan0" {
		t.Fatalf("expected wlan0, got %s", selected.Name)
	}
}

func TestSelectDefaultInterfaceSkipsVirtualInterfaces(t *testing.T) {
	interfaces := []net.Interface{
		{Name: "lo", Index: 1, Flags: net.FlagUp | net.FlagLoopback},
		{Name: "tun0", Index: 2, Flags: net.FlagUp | net.FlagRunning},
	}

	selected := selectDefaultInterface(interfaces)
	if selected != nil {
		t.Fatalf("expected no default interface, got %s", selected.Name)
	}
}

func TestClassifyInterfaceType(t *testing.T) {
	if got := classifyInterfaceType("wlan0"); got != libbox.InterfaceTypeWIFI {
		t.Fatalf("expected wifi type, got %d", got)
	}
	if got := classifyInterfaceType("rmnet_data0"); got != libbox.InterfaceTypeCellular {
		t.Fatalf("expected cellular type, got %d", got)
	}
	if got := classifyInterfaceType("eth0"); got != libbox.InterfaceTypeEthernet {
		t.Fatalf("expected ethernet type, got %d", got)
	}
}

func TestGetInterfacesUsesPlatformSnapshots(t *testing.T) {
	adapter := &platformAdapter{
		platform: fakePlatform{
			networkInterfaces: `[{"index":7,"mtu":1500,"name":"wlan0","addresses":["192.0.2.142/24"],"flags":65,"type":0,"dns_servers":["223.5.5.5"],"metered":false,"is_default":true}]`,
		},
	}

	iterator, err := adapter.GetInterfaces()
	if err != nil {
		t.Fatalf("GetInterfaces returned error: %v", err)
	}
	if !iterator.HasNext() {
		t.Fatal("expected one platform interface")
	}

	next := iterator.Next()
	if next == nil {
		t.Fatal("expected platform interface value")
	}
	if next.Name != "wlan0" {
		t.Fatalf("expected wlan0, got %q", next.Name)
	}
	if next.Index != 7 {
		t.Fatalf("expected interface index 7, got %d", next.Index)
	}
	if next.Type != libbox.InterfaceTypeWIFI {
		t.Fatalf("expected wifi type, got %d", next.Type)
	}
	if !next.Addresses.HasNext() || next.Addresses.Next() != "192.0.2.142/24" {
		t.Fatal("expected platform interface addresses to be preserved")
	}
	if !next.DNSServer.HasNext() || next.DNSServer.Next() != "223.5.5.5" {
		t.Fatal("expected platform DNS servers to be preserved")
	}
}

func TestSelectDefaultPlatformInterfacePrefersExplicitDefault(t *testing.T) {
	interfaces := []platformNetworkInterfaceSnapshot{
		{Name: "rmnet_data0", Index: 5, Type: libbox.InterfaceTypeCellular},
		{Name: "wlan0", Index: 7, Type: libbox.InterfaceTypeWIFI, Default: true},
	}

	selected := selectDefaultPlatformInterface(interfaces)
	if selected == nil {
		t.Fatal("expected a default platform interface")
	}
	if selected.Name != "wlan0" {
		t.Fatalf("expected wlan0, got %s", selected.Name)
	}
}
