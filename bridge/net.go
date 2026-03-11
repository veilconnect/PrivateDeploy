package bridge

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

func (a *App) Requests(method string, url string, headers map[string]string, body string, options RequestOptions) HTTPResult {
	log.Printf("Requests: %v %v %v %v %v", method, url, headers, body, options)

	client, ctx, cancel := withRequestOptionsClient(options)

	req, err := http.NewRequestWithContext(ctx, method, url, strings.NewReader(body))
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	req.Header = GetHeader(headers)

	if options.CancelId != "" {
		runtime.EventsOn(a.Ctx, options.CancelId, func(data ...any) {
			log.Printf("Requests Canceled: %v %v", method, url)
			cancel()
		})
		defer runtime.EventsOff(a.Ctx, options.CancelId)
	}

	resp, err := client.Do(req)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	return HTTPResult{true, resp.StatusCode, resp.Header, string(b)}
}

func (a *App) Download(method string, url string, path string, headers map[string]string, event string, options RequestOptions) HTTPResult {
	log.Printf("Download: %s %s %s %v %s %v", method, url, path, headers, event, options)

	client, ctx, cancel := withRequestOptionsClient(options)

	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	req.Header = GetHeader(headers)

	if options.CancelId != "" {
		runtime.EventsOn(a.Ctx, options.CancelId, func(data ...any) {
			log.Printf("Download Canceled: %v %v", url, path)
			cancel()
		})
		defer runtime.EventsOff(a.Ctx, options.CancelId)
	}

	resp, err := client.Do(req)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}
	defer resp.Body.Close()

	path = GetPath(path)

	err = os.MkdirAll(filepath.Dir(path), 0o750)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	file, err := os.Create(path)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}
	defer file.Close()

	reader := wrapWithProgress(resp.Body, resp.ContentLength, event, a)

	_, err = io.Copy(file, reader)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	return HTTPResult{true, resp.StatusCode, resp.Header, "Success"}
}

func (a *App) Upload(method string, url string, path string, headers map[string]string, event string, options RequestOptions) HTTPResult {
	log.Printf("Upload: %s %s %s %v %s %v", method, url, path, headers, event, options)

	path = GetPath(path)

	file, err := os.Open(path)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}
	defer file.Close()

	fileStat, err := file.Stat()
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	part, err := writer.CreateFormFile(options.FileField, path)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	reader := wrapWithProgress(file, fileStat.Size(), event, a)

	_, err = io.Copy(part, reader)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	err = writer.Close()
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	client, ctx, cancel := withRequestOptionsClient(options)

	if options.CancelId != "" {
		runtime.EventsOn(a.Ctx, options.CancelId, func(data ...any) {
			log.Printf("Upload Canceled: %v %v", url, path)
			cancel()
		})
		defer runtime.EventsOff(a.Ctx, options.CancelId)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	req.Header = GetHeader(headers)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := client.Do(req)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return HTTPResult{false, 500, nil, err.Error()}
	}

	return HTTPResult{true, resp.StatusCode, resp.Header, string(b)}
}

// GetAvailablePort returns an available TCP port on localhost.
func (a *App) GetAvailablePort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()

	addr, ok := listener.Addr().(*net.TCPAddr)
	if !ok {
		return 0, errors.New("unexpected addr type")
	}
	return addr.Port, nil
}

func (wt *WriteTracker) Write(p []byte) (n int, err error) {
	n = len(p)
	wt.Progress += int64(n)

	shouldEmit := wt.Total <= 0 || wt.Progress-wt.LastEmitted >= wt.EmitThreshold || wt.Progress == wt.Total
	if shouldEmit {
		runtime.EventsEmit(wt.App.Ctx, wt.ProgressChange, wt.Progress, wt.Total)
		wt.LastEmitted = wt.Progress
	}

	return n, nil
}

func wrapWithProgress(r io.Reader, size int64, event string, a *App) io.Reader {
	if event == "" {
		return r
	}
	return io.TeeReader(r, &WriteTracker{
		Total:          size,
		EmitThreshold:  128 * 1024,
		ProgressChange: event,
		App:            a,
	})
}

func withRequestOptionsClient(options RequestOptions) (*http.Client, context.Context, context.CancelFunc) {
	client := &http.Client{
		Timeout: GetTimeout(options.Timeout),
		Transport: &http.Transport{
			Proxy: GetProxy(options.Proxy),
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: options.Insecure,
			},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if !options.Redirect {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}

	ctx, cancel := context.WithCancel(context.Background())

	return client, ctx, cancel
}

// TestTCPPort tests if a TCP port is open on the given IP address
func TestTCPPort(ip string, port int, timeout int) bool {
	address := net.JoinHostPort(ip, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, GetTimeout(timeout))
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

type connectivityProbeTarget struct {
	Name    string `json:"name"`
	Port    int    `json:"port"`
	Network string `json:"network"`
}

type connectivityProbeRequest struct {
	Ports      []int                     `json:"ports,omitempty"` // backward-compatible alias for tcpPorts
	TCPPorts   []int                     `json:"tcpPorts,omitempty"`
	UDPPorts   []int                     `json:"udpPorts,omitempty"`
	Targets    []connectivityProbeTarget `json:"targets,omitempty"`
	ProbeICMP  *bool                     `json:"probeICMP,omitempty"`
	TCPTimeout int                       `json:"tcpTimeoutMs,omitempty"`
	UDPTimeout int                       `json:"udpTimeoutMs,omitempty"`
}

func normalizePorts(raw []int) []int {
	if len(raw) == 0 {
		return nil
	}
	seen := make(map[int]struct{}, len(raw))
	out := make([]int, 0, len(raw))
	for _, port := range raw {
		if port <= 0 || port > 65535 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		out = append(out, port)
	}
	sort.Ints(out)
	return out
}

func parseConnectivityProbeRequest(raw string) connectivityProbeRequest {
	req := connectivityProbeRequest{
		TCPTimeout: 2500,
		UDPTimeout: 1800,
	}

	raw = strings.TrimSpace(raw)
	if raw == "" {
		return req
	}

	var ports []int
	if err := json.Unmarshal([]byte(raw), &ports); err == nil {
		req.TCPPorts = normalizePorts(ports)
		return req
	}

	var parsed connectivityProbeRequest
	if err := json.Unmarshal([]byte(raw), &parsed); err == nil {
		parsed.TCPPorts = normalizePorts(append(parsed.TCPPorts, parsed.Ports...))
		parsed.UDPPorts = normalizePorts(parsed.UDPPorts)
		if parsed.TCPTimeout <= 0 {
			parsed.TCPTimeout = req.TCPTimeout
		}
		if parsed.UDPTimeout <= 0 {
			parsed.UDPTimeout = req.UDPTimeout
		}
		targets := make([]connectivityProbeTarget, 0, len(parsed.Targets))
		for _, target := range parsed.Targets {
			network := strings.ToLower(strings.TrimSpace(target.Network))
			if network != "tcp" && network != "udp" {
				continue
			}
			if target.Port <= 0 || target.Port > 65535 {
				continue
			}
			name := strings.TrimSpace(target.Name)
			if name == "" {
				name = fmt.Sprintf("%s:%d", network, target.Port)
			}
			targets = append(targets, connectivityProbeTarget{
				Name:    name,
				Port:    target.Port,
				Network: network,
			})
			if network == "tcp" {
				parsed.TCPPorts = append(parsed.TCPPorts, target.Port)
			} else {
				parsed.UDPPorts = append(parsed.UDPPorts, target.Port)
			}
		}
		parsed.Targets = targets
		parsed.TCPPorts = normalizePorts(parsed.TCPPorts)
		parsed.UDPPorts = normalizePorts(parsed.UDPPorts)
		return parsed
	}

	legacy := strings.Trim(raw, "[]")
	if legacy == "" {
		return req
	}
	for _, part := range strings.Split(legacy, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		var port int
		if _, err := fmt.Sscanf(part, "%d", &port); err == nil {
			req.TCPPorts = append(req.TCPPorts, port)
		}
	}
	req.TCPPorts = normalizePorts(req.TCPPorts)
	return req
}

func testICMPReachability(ip string, timeout time.Duration) (bool, string) {
	if net.ParseIP(ip) == nil {
		return false, "invalid_ip"
	}

	var args []string
	switch goruntime.GOOS {
	case "windows":
		timeoutMs := int(timeout.Milliseconds())
		if timeoutMs <= 0 {
			timeoutMs = 2000
		}
		args = []string{"-n", "1", "-w", fmt.Sprintf("%d", timeoutMs), ip}
	default:
		timeoutSec := int(timeout.Seconds())
		if timeoutSec <= 0 {
			timeoutSec = 2
		}
		args = []string{"-c", "1", "-W", fmt.Sprintf("%d", timeoutSec), ip}
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout+1500*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ping", args...)
	if err := cmd.Run(); err != nil {
		var notFound *exec.Error
		if errors.As(err, &notFound) {
			return false, "ping_unavailable"
		}
		return false, "ping"
	}

	return true, "ping"
}

func testTCPBaselineReachability(ip string, timeout time.Duration) bool {
	for _, port := range []int{80, 443} {
		address := net.JoinHostPort(ip, fmt.Sprintf("%d", port))
		conn, err := net.DialTimeout("tcp", address, timeout)
		if err == nil {
			conn.Close()
			return true
		}
	}
	return false
}

func probeUDPPort(ip string, port int, timeout time.Duration) string {
	address := net.JoinHostPort(ip, fmt.Sprintf("%d", port))
	udpAddr, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		return "error"
	}

	conn, err := net.DialUDP("udp", nil, udpAddr)
	if err != nil {
		return "closed"
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(timeout))

	if _, err := conn.Write([]byte{0x00}); err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "refused") {
			return "closed"
		}
		return "error"
	}

	buf := make([]byte, 8)
	_, err = conn.Read(buf)
	if err == nil {
		return "open"
	}

	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		// UDP services often don't answer unknown payloads.
		return "open_or_filtered"
	}
	if strings.Contains(strings.ToLower(err.Error()), "refused") {
		return "closed"
	}
	return "unknown"
}

// TestConnectivity tests the connectivity to a given IP and ports
// Returns a JSON string with the test results
func (a *App) TestConnectivity(ip string, portsJSON string) FlagResult {
	log.Printf("TestConnectivity: %s ports=%s", ip, portsJSON)
	req := parseConnectivityProbeRequest(portsJSON)

	probeICMP := true
	if req.ProbeICMP != nil {
		probeICMP = *req.ProbeICMP
	}

	icmpReachable := false
	icmpMethod := "skipped"
	if probeICMP {
		icmpReachable, icmpMethod = testICMPReachability(ip, 2*time.Second)
	}
	baselineReachable := testTCPBaselineReachability(ip, 1500*time.Millisecond)

	tcpPortsOpen := make(map[string]bool, len(req.TCPPorts))
	udpPortsStatus := make(map[string]string, len(req.UDPPorts))
	portsOpen := make(map[string]bool, len(req.TCPPorts)+len(req.UDPPorts))
	targetStatus := make(map[string]string, len(req.Targets))

	anyTransportReachable := false
	for _, port := range req.TCPPorts {
		portStr := fmt.Sprintf("%d", port)
		isOpen := TestTCPPort(ip, port, req.TCPTimeout)
		tcpPortsOpen[portStr] = isOpen
		portsOpen[portStr] = isOpen
		if isOpen {
			anyTransportReachable = true
		}
	}

	for _, port := range req.UDPPorts {
		portStr := fmt.Sprintf("%d", port)
		status := probeUDPPort(ip, port, time.Duration(req.UDPTimeout)*time.Millisecond)
		udpPortsStatus[portStr] = status
		openLike := status == "open" || status == "open_or_filtered"
		portsOpen[portStr] = openLike
		if openLike {
			anyTransportReachable = true
		}
	}

	for _, target := range req.Targets {
		portKey := fmt.Sprintf("%d", target.Port)
		switch target.Network {
		case "tcp":
			if open, ok := tcpPortsOpen[portKey]; ok && open {
				targetStatus[target.Name] = "open"
			} else {
				targetStatus[target.Name] = "closed"
			}
		case "udp":
			if status, ok := udpPortsStatus[portKey]; ok {
				targetStatus[target.Name] = status
			} else {
				targetStatus[target.Name] = "unknown"
			}
		}
	}

	icmpSignal := icmpReachable
	if icmpMethod != "ping" {
		icmpSignal = baselineReachable
	}

	status := "blocked"
	if anyTransportReachable {
		if icmpSignal {
			status = "reachable"
		} else {
			status = "icmp_blocked"
		}
	} else if len(req.TCPPorts) == 0 && len(req.UDPPorts) == 0 && icmpSignal {
		status = "reachable"
	}

	result := map[string]interface{}{
		"ip":                ip,
		"icmpReachable":     icmpReachable,
		"icmpMethod":        icmpMethod,
		"baselineReachable": baselineReachable,
		"portsOpen":         portsOpen,
		"tcpPortsOpen":      tcpPortsOpen,
		"udpPortsStatus":    udpPortsStatus,
		"targetStatus":      targetStatus,
		"status":            status,
	}

	// Convert result to JSON
	jsonBytes, err := json.Marshal(result)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(jsonBytes)}
}
