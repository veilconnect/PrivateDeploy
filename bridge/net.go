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
	"path/filepath"
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

	err = os.MkdirAll(filepath.Dir(path), os.ModePerm)
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

// TestConnectivity tests the connectivity to a given IP and ports
// Returns a JSON string with the test results
func (a *App) TestConnectivity(ip string, portsJSON string) FlagResult {
	log.Printf("TestConnectivity: %s ports=%s", ip, portsJSON)

	// Parse ports from JSON array string like "[22, 80, 443]"
	ports := []int{}
	portsJSON = strings.TrimSpace(portsJSON)
	if portsJSON != "" && portsJSON != "[]" {
		// Simple JSON array parsing
		portsJSON = strings.Trim(portsJSON, "[]")
		portStrs := strings.Split(portsJSON, ",")
		for _, portStr := range portStrs {
			portStr = strings.TrimSpace(portStr)
			var port int
			if _, err := fmt.Sscanf(portStr, "%d", &port); err == nil && port > 0 {
				ports = append(ports, port)
			}
		}
	}

	result := map[string]interface{}{
		"ip":             ip,
		"icmpReachable":  false,
		"portsOpen":      map[string]bool{},
		"status":         "unknown",
	}

	// Test ICMP (ping) - using TCP connection to port 80 as fallback
	// Note: ICMP requires root privileges, so we use TCP as a connectivity check
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Try to resolve the IP first
	dialer := &net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip, "80"))
	if err == nil {
		conn.Close()
		result["icmpReachable"] = true
	}

	// Test each port
	portsOpen := make(map[string]bool)
	anyPortOpen := false
	for _, port := range ports {
		portStr := fmt.Sprintf("%d", port)
		isOpen := TestTCPPort(ip, port, 5000) // 5 second timeout
		portsOpen[portStr] = isOpen
		if isOpen {
			anyPortOpen = true
		}
	}
	result["portsOpen"] = portsOpen

	// Determine overall status
	if result["icmpReachable"].(bool) && (len(ports) == 0 || anyPortOpen) {
		result["status"] = "reachable"
	} else if !result["icmpReachable"].(bool) && anyPortOpen {
		result["status"] = "icmp_blocked"
	} else {
		result["status"] = "blocked"
	}

	// Convert result to JSON
	jsonBytes, err := json.Marshal(result)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}

	return FlagResult{Flag: true, Data: string(jsonBytes)}
}
