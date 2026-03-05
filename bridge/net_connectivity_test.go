package bridge

import "testing"

func TestNormalizePorts(t *testing.T) {
	ports := normalizePorts([]int{443, 0, 443, 65536, 80, -1, 53})
	if len(ports) != 3 {
		t.Fatalf("expected 3 valid ports, got %d (%v)", len(ports), ports)
	}
	expected := []int{53, 80, 443}
	for i, p := range expected {
		if ports[i] != p {
			t.Fatalf("expected port[%d]=%d, got %d", i, p, ports[i])
		}
	}
}

func TestParseConnectivityProbeRequestArray(t *testing.T) {
	req := parseConnectivityProbeRequest("[22, 443, 22]")
	if len(req.TCPPorts) != 2 {
		t.Fatalf("expected deduped tcp ports, got %v", req.TCPPorts)
	}
	if req.TCPPorts[0] != 22 || req.TCPPorts[1] != 443 {
		t.Fatalf("unexpected tcp port ordering: %v", req.TCPPorts)
	}
	if len(req.UDPPorts) != 0 {
		t.Fatalf("expected empty udp ports, got %v", req.UDPPorts)
	}
}

func TestParseConnectivityProbeRequestObject(t *testing.T) {
	raw := `{
		"tcpPorts": [443, 443, 80],
		"udpPorts": [8443, 0, 8443],
		"targets": [
			{"name": "hysteria2", "port": 8443, "network": "udp"},
			{"name": "bad", "port": 0, "network": "udp"},
			{"name": "vless", "port": 443, "network": "tcp"}
		],
		"tcpTimeoutMs": 0,
		"udpTimeoutMs": 0
	}`

	req := parseConnectivityProbeRequest(raw)
	if len(req.TCPPorts) != 2 || req.TCPPorts[0] != 80 || req.TCPPorts[1] != 443 {
		t.Fatalf("unexpected tcp ports: %v", req.TCPPorts)
	}
	if len(req.UDPPorts) != 1 || req.UDPPorts[0] != 8443 {
		t.Fatalf("unexpected udp ports: %v", req.UDPPorts)
	}
	if len(req.Targets) != 2 {
		t.Fatalf("expected 2 valid targets, got %d (%v)", len(req.Targets), req.Targets)
	}
	if req.TCPTimeout <= 0 || req.UDPTimeout <= 0 {
		t.Fatalf("expected defaulted timeouts, got tcp=%d udp=%d", req.TCPTimeout, req.UDPTimeout)
	}
}
