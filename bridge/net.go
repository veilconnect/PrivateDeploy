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
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	xproxy "golang.org/x/net/proxy"
)

var defaultSpeedTestURLs = []string{
	"https://speed.cloudflare.com/__down?bytes=1000000",
	"https://speed.hetzner.de/1MB.bin",
	"https://proof.ovh.net/files/1Mb.dat",
}

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

// TestNodeSpeed measures TCP connection latency to the best available proxy port.
// Tests multiple ports and returns the lowest latency in milliseconds.
func (a *App) TestNodeSpeed(ip string, portsJSON string) FlagResult {
	log.Printf("TestNodeSpeed: %s ports=%s", ip, portsJSON)
	req := parseConnectivityProbeRequest(portsJSON)

	var tcpPorts []int
	for _, t := range req.Targets {
		if t.Network == "tcp" {
			tcpPorts = append(tcpPorts, t.Port)
		}
	}
	if len(tcpPorts) == 0 {
		tcpPorts = req.TCPPorts
	}
	if len(tcpPorts) == 0 {
		// Fallback: test SSH port (22) for basic latency measurement
		tcpPorts = []int{22}
	}

	type portLatency struct {
		port    int
		latency time.Duration
	}

	const rounds = 3
	timeout := 5 * time.Second
	if req.TCPTimeout > 0 {
		timeout = time.Duration(req.TCPTimeout) * time.Millisecond
	}

	var mu sync.Mutex
	var results []portLatency
	var wg sync.WaitGroup

	for _, port := range tcpPorts {
		wg.Add(1)
		go func(p int) {
			defer wg.Done()
			addr := net.JoinHostPort(ip, fmt.Sprintf("%d", p))
			var best time.Duration
			for i := 0; i < rounds; i++ {
				start := time.Now()
				conn, err := net.DialTimeout("tcp", addr, timeout)
				elapsed := time.Since(start)
				if err != nil {
					continue
				}
				conn.Close()
				if best == 0 || elapsed < best {
					best = elapsed
				}
			}
			if best > 0 {
				mu.Lock()
				results = append(results, portLatency{p, best})
				mu.Unlock()
			}
		}(port)
	}
	wg.Wait()

	if len(results) == 0 {
		return FlagResult{false, `{"latencyMs":-1,"status":"timeout"}`}
	}

	// Find lowest latency
	best := results[0]
	for _, r := range results[1:] {
		if r.latency < best.latency {
			best = r
		}
	}

	latencyMs := float64(best.latency.Microseconds()) / 1000.0
	data := fmt.Sprintf(`{"latencyMs":%.1f,"port":%d,"status":"ok"}`, latencyMs, best.port)
	log.Printf("TestNodeSpeed result: %s -> %s", ip, data)
	return FlagResult{true, data}
}

// TestDownloadSpeed measures download speed through a proxy by downloading a test file.
// proxyURL: e.g. "socks5://127.0.0.1:20122" or "http://127.0.0.1:20121", empty for direct
// Returns JSON with speedMbps, bytes downloaded, elapsed time
func (a *App) TestDownloadSpeed(proxyURL string, testURL string, timeoutSec int) FlagResult {
	log.Printf("TestDownloadSpeed: proxy=%s url=%s timeout=%ds", proxyURL, testURL, timeoutSec)

	if testURL == "" {
		testURL = defaultSpeedTestURLs[0]
	}
	if timeoutSec <= 0 {
		timeoutSec = 15
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: false},
	}

	// Support SOCKS5 proxy via x/net/proxy (http.Transport.Proxy only handles HTTP)
	if strings.HasPrefix(proxyURL, "socks5://") || strings.HasPrefix(proxyURL, "socks://") {
		parsed, err := url.Parse(proxyURL)
		if err == nil {
			dialer, dErr := xproxy.FromURL(parsed, xproxy.Direct)
			if dErr == nil {
				// Pass the domain name directly to the SOCKS5 proxy so that
				// DNS resolution happens on the remote server (via sing-box's
				// outbound).  Local DNS resolution can return poisoned or
				// unreachable IPs in restricted network environments.
				transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
					if ctxDialer, ok := dialer.(xproxy.ContextDialer); ok {
						return ctxDialer.DialContext(ctx, network, addr)
					}
					return dialer.Dial(network, addr)
				}
			}
		}
	} else if proxyURL != "" {
		transport.Proxy = GetProxy(proxyURL)
	}

	client := &http.Client{
		Timeout:   time.Duration(timeoutSec) * time.Second,
		Transport: transport,
	}

	start := time.Now()
	resp, err := client.Get(testURL)
	if err != nil {
		log.Printf("TestDownloadSpeed error: %v", err)
		return speedError(err.Error())
	}
	defer resp.Body.Close()

	n, err := io.Copy(io.Discard, resp.Body)
	elapsed := time.Since(start)

	if err != nil {
		log.Printf("TestDownloadSpeed read error: %v", err)
		if result, ok := buildPartialSpeedResult(testURL, n, elapsed, err); ok {
			log.Printf("TestDownloadSpeed partial result: %s", result)
			return FlagResult{true, result}
		}
		return speedError(err.Error())
	}

	elapsedSec := elapsed.Seconds()
	if elapsedSec <= 0 {
		elapsedSec = 0.001
	}
	speedMbps := float64(n*8) / elapsedSec / 1_000_000.0

	data := fmt.Sprintf(`{"speedMbps":%.2f,"bytes":%d,"elapsedMs":%.0f,"status":"ok"}`, speedMbps, n, elapsed.Seconds()*1000)
	log.Printf("TestDownloadSpeed result: %s", data)
	return FlagResult{true, data}
}

func buildPartialSpeedResult(testURL string, bytesRead int64, elapsed time.Duration, readErr error) (string, bool) {
	if bytesRead <= 0 || elapsed <= 0 {
		return "", false
	}

	minimumSampleBytes := int64(128 * 1024)
	expectedBytes := expectedSpeedSampleBytes(testURL)
	if expectedBytes > 0 {
		threshold := expectedBytes / 4
		if threshold < minimumSampleBytes {
			threshold = minimumSampleBytes
		}
		if bytesRead < threshold {
			return "", false
		}
	} else if bytesRead < minimumSampleBytes {
		return "", false
	}

	elapsedSec := elapsed.Seconds()
	if elapsedSec <= 0 {
		elapsedSec = 0.001
	}
	speedMbps := float64(bytesRead*8) / elapsedSec / 1_000_000.0
	escapedErr, _ := json.Marshal(readErr.Error())
	data := fmt.Sprintf(`{"speedMbps":%.2f,"bytes":%d,"elapsedMs":%.0f,"status":"partial","error":%s}`,
		speedMbps,
		bytesRead,
		elapsed.Seconds()*1000,
		string(escapedErr),
	)
	return data, true
}

func expectedSpeedSampleBytes(testURL string) int64 {
	parsed, err := url.Parse(testURL)
	if err != nil {
		return 0
	}
	raw := parsed.Query().Get("bytes")
	if raw == "" {
		return 0
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

type speedTestResultPayload struct {
	Status string `json:"status"`
	Error  string `json:"error"`
}

func parseSpeedTestResultPayload(data string) speedTestResultPayload {
	var payload speedTestResultPayload
	if err := json.Unmarshal([]byte(data), &payload); err != nil {
		return speedTestResultPayload{}
	}
	return payload
}

func isRetryableSpeedFailure(message string) bool {
	if strings.TrimSpace(message) == "" {
		return false
	}
	normalized := strings.ToLower(message)
	for _, marker := range []string{
		"socks server failure",
		"socks5:",
		"proxyconnect",
		"proxy error",
		"connection reset",
		"broken pipe",
		"eof",
		"timeout",
		"timed out",
		"deadline exceeded",
		"no route to host",
		"network is unreachable",
		"connection refused",
		"connect tcp",
		"temporary failure",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func benchmarkAttemptCountForURL(index int) int {
	if index == 0 {
		return 3
	}
	return 1
}

func benchmarkRetryDelay(attempt int) time.Duration {
	switch attempt {
	case 0:
		return 350 * time.Millisecond
	case 1:
		return 900 * time.Millisecond
	default:
		return 1500 * time.Millisecond
	}
}

func (a *App) testNodeDownloadBenchmark(proxyURL string, timeoutSec int) FlagResult {
	lastResult := speedError("speed test failed")

	for urlIndex, testURL := range defaultSpeedTestURLs {
		attempts := benchmarkAttemptCountForURL(urlIndex)
		for attempt := 0; attempt < attempts; attempt++ {
			if attempt > 0 {
				time.Sleep(benchmarkRetryDelay(attempt - 1))
			}

			result := a.TestDownloadSpeed(proxyURL, testURL, timeoutSec)
			payload := parseSpeedTestResultPayload(result.Data)
			if payload.Status == "ok" || payload.Status == "partial" {
				return result
			}

			lastResult = result
			if !isRetryableSpeedFailure(payload.Error) {
				break
			}
			log.Printf(
				"TestNodeDirectSpeed retrying benchmark url=%s attempt=%d error=%s",
				testURL,
				attempt+1,
				payload.Error,
			)
		}
	}

	return lastResult
}

// TestNodeDirectSpeed tests download speed for a node by spawning a temporary sing-box
// process with the node's outbound config, without requiring the main kernel to have this node.
// outboundsJSON: JSON array of sing-box outbound objects for this node
// Returns JSON with speedMbps, bytes, elapsedMs, status
func (a *App) TestNodeDirectSpeed(outboundsJSON string, timeoutSec int) FlagResult {
	log.Printf("TestNodeDirectSpeed: outbounds=%d bytes timeout=%ds", len(outboundsJSON), timeoutSec)

	if timeoutSec <= 0 {
		timeoutSec = 15
	}

	// Parse outbounds
	var outbounds []json.RawMessage
	if err := json.Unmarshal([]byte(outboundsJSON), &outbounds); err != nil {
		return speedError("invalid outbounds: " + err.Error())
	}
	if len(outbounds) == 0 {
		return speedError("no outbounds provided")
	}

	// Find sing-box binary
	singboxPath := findSingboxBinaryFromEnv()
	if singboxPath == "" {
		return speedError(fmt.Sprintf("sing-box binary not found (basePath=%s)", Env.BasePath))
	}

	var bestPartial *speedProbeResult
	var lastError string

	for index, outbound := range outbounds {
		tag := speedProbeTag(outbound, index)
		result := a.testNodeDirectSpeedSingleOutbound(outbound, timeoutSec, singboxPath)
		parsed, ok := decodeSpeedProbeResult(result.Data)
		if !ok {
			if result.Data != "" {
				lastError = result.Data
			}
			continue
		}

		switch parsed.Status {
		case "ok":
			if index > 0 {
				log.Printf("TestNodeDirectSpeed: fallback outbound succeeded tag=%s attempt=%d/%d", tag, index+1, len(outbounds))
			}
			return result
		case "partial":
			candidate := parsed
			if bestPartial == nil || candidate.SpeedMbps > bestPartial.SpeedMbps {
				bestPartial = &candidate
			}
		default:
			if parsed.Error != "" {
				lastError = parsed.Error
			}
		}
	}

	if bestPartial != nil {
		payload, err := json.Marshal(bestPartial)
		if err == nil {
			return FlagResult{Flag: true, Data: string(payload)}
		}
	}

	if lastError == "" {
		lastError = "speed test failed"
	}
	return speedError(lastError)
}

func (a *App) testNodeDirectSpeedSingleOutbound(outbound json.RawMessage, timeoutSec int, singboxPath string) FlagResult {
	if len(outbound) == 0 {
		return speedError("no outbound provided")
	}

	// Get a free port for the temporary SOCKS5 inbound
	localPort, err := getAvailablePort()
	if err != nil {
		return speedError("no free port: " + err.Error())
	}

	// Use the first outbound's tag as the default route
	var firstOutbound struct {
		Tag string `json:"tag"`
	}
	json.Unmarshal(outbound, &firstOutbound)
	if firstOutbound.Tag == "" {
		firstOutbound.Tag = "speed-test-proxy"
		// Inject tag into outbound
		var ob map[string]interface{}
		json.Unmarshal(outbound, &ob)
		ob["tag"] = firstOutbound.Tag
		outbound, _ = json.Marshal(ob)
	}

	// Build temporary sing-box config — keep minimal for maximum compatibility
	tmpConfig := map[string]interface{}{
		"log": map[string]interface{}{
			"disabled": false,
			"level":    "info",
		},
		"inbounds": []map[string]interface{}{
			{
				"type":        "socks",
				"tag":         "socks-in",
				"listen":      "127.0.0.1",
				"listen_port": localPort,
			},
		},
		"outbounds": []json.RawMessage{outbound},
		"route": map[string]interface{}{
			"final":                 firstOutbound.Tag,
			"auto_detect_interface": false,
		},
		"dns": map[string]interface{}{
			"servers": []map[string]interface{}{
				{
					"tag":     "proxy-dns",
					"address": "https://1.1.1.1/dns-query",
					"detour":  firstOutbound.Tag,
				},
				{
					"tag":     "local-dns",
					"address": "https://223.5.5.5/dns-query",
				},
			},
			"final": "proxy-dns",
		},
	}

	configBytes, err := json.Marshal(tmpConfig)
	if err != nil {
		return speedError("config marshal: " + err.Error())
	}

	log.Printf("TestNodeDirectSpeed: binary=%s port=%d tag=%s", singboxPath, localPort, firstOutbound.Tag)

	// Write temp config file
	tmpFile, err := os.CreateTemp("", "pd-speedtest-*.json")
	if err != nil {
		return speedError("tmpfile: " + err.Error())
	}
	tmpFile.Write(configBytes)
	tmpFile.Close()
	defer os.Remove(tmpFile.Name())

	// Start temporary sing-box — use a plain exec.Command instead of
	// exec.CommandContext so that a context cancellation does not
	// TerminateProcess the sing-box while a download is still in flight
	// (on Windows TerminateProcess is immediate and non-graceful).
	cmd := exec.Command(singboxPath, "run", "--disable-color", "-c", tmpFile.Name())
	SetCmdWindowHidden(cmd)
	cmd.Env = append(os.Environ(),
		"ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true",
		"ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true",
	)

	var combinedBuf bytes.Buffer
	cmd.Stdout = &combinedBuf
	cmd.Stderr = &combinedBuf
	if err := cmd.Start(); err != nil {
		return speedError("start sing-box: " + err.Error())
	}
	defer func() {
		SendExitSignal(cmd.Process)
		cmd.Process.Kill()
		cmd.Wait()
	}()

	// Wait for the SOCKS5 port to become ready
	proxyURL := fmt.Sprintf("socks5://127.0.0.1:%d", localPort)
	ready := false
	for i := 0; i < 30; i++ {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", localPort), 200*time.Millisecond)
		if err == nil {
			conn.Close()
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		errMsg := strings.TrimSpace(combinedBuf.String())
		if errMsg == "" {
			errMsg = "sing-box socks not ready (no output from process)"
		}
		log.Printf("TestNodeDirectSpeed: sing-box failed: %s", errMsg)
		return speedError(errMsg)
	}

	// Give the outbound stack a moment to stabilize after the local SOCKS port
	// starts accepting connections. A listening SOCKS port does not necessarily
	// mean the remote protocol handshake is already ready for a benchmark.
	time.Sleep(500 * time.Millisecond)

	// Run the speed test through the temporary proxy with retries and fallback
	// URLs so a single transient endpoint/proxy race does not tank the node.
	result := a.testNodeDownloadBenchmark(proxyURL, timeoutSec)
	result = enrichSpeedProbeError(result, combinedBuf.String())
	log.Printf("TestNodeDirectSpeed result: %s", result.Data)
	return result
}

type speedProbeResult struct {
	SpeedMbps float64 `json:"speedMbps"`
	Bytes     int64   `json:"bytes,omitempty"`
	ElapsedMs float64 `json:"elapsedMs,omitempty"`
	Status    string  `json:"status"`
	Error     string  `json:"error,omitempty"`
}

func decodeSpeedProbeResult(data string) (speedProbeResult, bool) {
	if strings.TrimSpace(data) == "" {
		return speedProbeResult{}, false
	}

	var parsed speedProbeResult
	if err := json.Unmarshal([]byte(data), &parsed); err != nil {
		return speedProbeResult{}, false
	}
	if parsed.Status == "" {
		return speedProbeResult{}, false
	}
	return parsed, true
}

func speedProbeTag(outbound json.RawMessage, index int) string {
	var payload struct {
		Tag string `json:"tag"`
	}
	if err := json.Unmarshal(outbound, &payload); err == nil && strings.TrimSpace(payload.Tag) != "" {
		return payload.Tag
	}
	return fmt.Sprintf("outbound-%d", index+1)
}

func enrichSpeedProbeError(result FlagResult, logs string) FlagResult {
	parsed, ok := decodeSpeedProbeResult(result.Data)
	if !ok || parsed.Status != "error" || strings.TrimSpace(parsed.Error) == "" {
		return result
	}

	rootCause := extractSpeedProbeRootCause(logs)
	if rootCause == "" || rootCause == parsed.Error {
		return result
	}

	parsed.Error = rootCause
	payload, err := json.Marshal(parsed)
	if err != nil {
		return result
	}
	return FlagResult{Flag: result.Flag, Data: string(payload)}
}

func extractSpeedProbeRootCause(logs string) string {
	lines := strings.Split(logs, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" || !strings.Contains(line, "ERROR") {
			continue
		}
		if marker := "using outbound/"; strings.Contains(line, marker) {
			parts := strings.SplitN(line, marker, 2)
			if len(parts) == 2 {
				if idx := strings.Index(parts[1], ": "); idx >= 0 {
					cause := strings.TrimSpace(parts[1][idx+2:])
					if cause != "" {
						return cause
					}
				}
			}
		}
		if idx := strings.Index(line, "dial tcp "); idx >= 0 {
			return strings.TrimSpace(line[idx:])
		}
	}
	return ""
}

// speedError builds a JSON speed test error result with properly escaped error message.
func speedError(msg string) FlagResult {
	escapedMsg, _ := json.Marshal(msg)
	return FlagResult{false, fmt.Sprintf(`{"speedMbps":0,"status":"error","error":%s}`, string(escapedMsg))}
}

// findSingboxBinaryFromEnv locates the sing-box binary using the app's base path.
func findSingboxBinaryFromEnv() string {
	basePath := Env.BasePath
	exeDir := filepath.Dir(Env.ExecPath)
	candidates := []string{}
	if fromEnv := strings.TrimSpace(os.Getenv("PRIVATEDEPLOY_SINGBOX_PATH")); fromEnv != "" {
		candidates = append(candidates, fromEnv)
	}

	suffix := ""
	if goruntime.GOOS == "windows" {
		suffix = ".exe"
	}

	if basePath != "" {
		candidates = append(candidates,
			filepath.Join(basePath, "data", "sing-box", "sing-box"+suffix),
			filepath.Join(basePath, "data", "sing-box", "sing-box-latest"+suffix),
		)
	}
	// On Windows the exe directory may differ from basePath (e.g. Program Files
	// vs %LOCALAPPDATA%), so also search relative to the executable itself.
	if exeDir != "" && exeDir != basePath {
		candidates = append(candidates,
			filepath.Join(exeDir, "data", "sing-box", "sing-box"+suffix),
			filepath.Join(exeDir, "data", "sing-box", "sing-box-latest"+suffix),
			filepath.Join(exeDir, "sing-box"+suffix),
		)
	}
	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return c
		}
	}
	if fromPath, err := exec.LookPath("sing-box"); err == nil {
		return fromPath
	}
	return ""
}

// DiagnoseSingbox checks sing-box binary availability and runs a quick version check.
// Returns a JSON string with diagnostic info for troubleshooting.
func (a *App) DiagnoseSingbox() FlagResult {
	basePath := Env.BasePath
	exeDir := filepath.Dir(Env.ExecPath)

	singboxPath := findSingboxBinaryFromEnv()

	info := map[string]interface{}{
		"basePath":    basePath,
		"exeDir":      exeDir,
		"os":          goruntime.GOOS,
		"arch":        goruntime.GOARCH,
		"singboxPath": singboxPath,
		"found":       singboxPath != "",
	}

	if singboxPath != "" {
		fi, err := os.Stat(singboxPath)
		if err == nil {
			info["singboxSize"] = fi.Size()
			info["singboxMode"] = fi.Mode().String()
		}

		// Try running sing-box version
		cmd := exec.Command(singboxPath, "version")
		SetCmdWindowHidden(cmd)
		out, err := cmd.CombinedOutput()
		if err != nil {
			info["versionError"] = err.Error()
			info["versionOutput"] = string(out)
		} else {
			info["version"] = strings.TrimSpace(string(out))
		}
	}

	data, _ := json.Marshal(info)
	log.Printf("DiagnoseSingbox: %s", string(data))
	return FlagResult{singboxPath != "", string(data)}
}

// getAvailablePort returns an available TCP port on localhost (non-exported helper).
func getAvailablePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
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
