package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/providers/internal/provutil"

	"golang.org/x/net/proxy"
)

const (
	defaultProtocolProbeURL       = "https://www.cloudflare.com/cdn-cgi/trace"
	defaultProtocolProbeTimeout   = 20 * time.Second
	defaultProtocolRepairAttempts = 1
	defaultProtocolProbeAttempts  = 3
	protocolProbeBootGrace        = 12 * time.Second
	protocolProbeRetryDelay       = 2 * time.Second
	localSOCKSReadyTimeout        = 5 * time.Second
	localSOCKSDialTimeout         = 400 * time.Millisecond
)

type protocolProbeTarget struct {
	name     string
	outbound map[string]any
}

func (p *Provider) ensureProtocolReadinessWithRepair(
	ctx context.Context,
	instanceID string,
	dropletID int,
	ports deploy.PortAssignment,
	extra map[string]string,
) (*cloud.Instance, error) {
	if !parseBoolOrDefault(firstExtraValue(extra,
		"protocolProbeEnabled", "protocol_probe_enabled", "protocolReadyProbe", "protocol_ready_probe",
	), true) {
		return nil, nil
	}

	singboxPath := findSingboxBinary(p.basePath)
	if singboxPath == "" {
		return nil, fmt.Errorf("sing-box binary not found for protocol readiness probe")
	}

	probeURL := normalizeProbeURL(firstExtraValue(extra,
		"protocolProbeURL", "protocol_probe_url", "readinessProbeURL", "readiness_probe_url",
	), defaultProtocolProbeURL)
	probeTimeout := parseProtocolProbeTimeout(extra, defaultProtocolProbeTimeout)
	repairAttempts := parseProtocolRepairAttempts(extra, defaultProtocolRepairAttempts)
	readyTimeout := provutil.ParseServiceReadyTimeout(extra, defaultServiceReadyTimeout)
	readyPorts := []int{ports.SSPort, ports.VLESSPort, ports.TrojanPort}

	var lastErr error

	for attempt := 0; attempt <= repairAttempts; attempt++ {
		current, err := p.waitForInstanceAndTCPPorts(ctx, instanceID, readyPorts, readyTimeout)
		if err != nil {
			lastErr = err
		} else if current != nil {
			if err := runProtocolProbes(ctx, singboxPath, *current, probeURL, probeTimeout); err == nil {
				return current, nil
			} else {
				lastErr = err
			}
		}

		if attempt == repairAttempts {
			break
		}

		if err := p.repairProtocolReadiness(ctx, instanceID, dropletID, ports, readyTimeout); err != nil {
			if lastErr != nil {
				lastErr = fmt.Errorf("%v; repair attempt %d failed: %w", lastErr, attempt+1, err)
			} else {
				lastErr = fmt.Errorf("repair attempt %d failed: %w", attempt+1, err)
			}
		}
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("protocol readiness probe failed without explicit error")
	}
	return nil, lastErr
}

func (p *Provider) repairProtocolReadiness(
	ctx context.Context,
	instanceID string,
	dropletID int,
	ports deploy.PortAssignment,
	readyTimeout time.Duration,
) error {
	// Re-attach firewall first in case of eventual-consistency/race in DO control-plane.
	if fwID, err := p.ensurePrivateDeployFirewall(ctx, ports); err == nil {
		_ = p.associateFirewallWithDroplet(ctx, fwID, dropletID)
	}

	if err := p.rebootDroplet(ctx, dropletID); err != nil {
		return err
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(protocolProbeBootGrace):
	}

	_, err := p.waitForInstanceAndTCPPorts(ctx, instanceID, []int{ports.SSPort, ports.VLESSPort, ports.TrojanPort}, readyTimeout)
	return err
}

func (p *Provider) rebootDroplet(ctx context.Context, dropletID int) error {
	payload := map[string]string{"type": "reboot"}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("%s/droplets/%d/actions", baseURL, dropletID), strings.NewReader(string(body)))
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusAccepted {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: reboot status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(respBody))
	}

	return nil
}

func runProtocolProbes(ctx context.Context, singboxPath string, instance cloud.Instance, probeURL string, timeout time.Duration) error {
	targets := buildProtocolProbeTargets(instance)
	if len(targets) == 0 {
		return nil
	}

	failures := make([]string, 0)
	for _, target := range targets {
		if err := runSingleProtocolProbe(ctx, singboxPath, target, probeURL, timeout); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", target.name, err))
		}
	}

	if len(failures) > 0 {
		return fmt.Errorf("protocol probe failures: %s", strings.Join(failures, "; "))
	}
	return nil
}

func buildProtocolProbeTargets(instance cloud.Instance) []protocolProbeTarget {
	ip := strings.TrimSpace(instance.IPv4)
	if ip == "" {
		ip = strings.TrimSpace(instance.IPv6)
	}
	if ip == "" {
		return nil
	}

	targets := make([]protocolProbeTarget, 0, 3)

	if instance.SSPort > 0 && strings.TrimSpace(instance.SSPassword) != "" {
		targets = append(targets, protocolProbeTarget{
			name: "shadowsocks",
			outbound: map[string]any{
				"type":        "shadowsocks",
				"tag":         "bench",
				"server":      ip,
				"server_port": instance.SSPort,
				"method":      "aes-256-gcm",
				"password":    instance.SSPassword,
			},
		})
	}

	if instance.VLESSPort > 0 &&
		strings.TrimSpace(instance.VLESSUUID) != "" &&
		strings.TrimSpace(instance.VLESSPublicKey) != "" &&
		strings.TrimSpace(instance.VLESSShortID) != "" {
		serverName := strings.TrimSpace(instance.VLESSServerName)
		if serverName == "" {
			serverName = deploy.DefaultVLESSServerName
		}

		targets = append(targets, protocolProbeTarget{
			name: "vless-reality",
			outbound: map[string]any{
				"type":        "vless",
				"tag":         "bench",
				"server":      ip,
				"server_port": instance.VLESSPort,
				"uuid":        instance.VLESSUUID,
				"flow":        "xtls-rprx-vision",
				"tls": map[string]any{
					"enabled":     true,
					"server_name": serverName,
					"utls": map[string]any{
						"enabled":     true,
						"fingerprint": "chrome",
					},
					"reality": map[string]any{
						"enabled":    true,
						"public_key": normalizeRealityPublicKey(instance.VLESSPublicKey),
						"short_id":   instance.VLESSShortID,
					},
				},
			},
		})
	}

	if instance.TrojanPort > 0 && strings.TrimSpace(instance.TrojanPassword) != "" {
		serverName := strings.TrimSpace(instance.TrojanServerName)
		if serverName == "" {
			serverName = deploy.DefaultTrojanServerName
		}
		insecure := true
		if instance.TrojanInsecure != nil {
			insecure = *instance.TrojanInsecure
		}

		targets = append(targets, protocolProbeTarget{
			name: "trojan",
			outbound: map[string]any{
				"type":        "trojan",
				"tag":         "bench",
				"server":      ip,
				"server_port": instance.TrojanPort,
				"password":    instance.TrojanPassword,
				"tls": map[string]any{
					"enabled":     true,
					"server_name": serverName,
					"insecure":    insecure,
				},
			},
		})
	}

	return targets
}

func runSingleProtocolProbe(ctx context.Context, singboxPath string, target protocolProbeTarget, probeURL string, timeout time.Duration) error {
	socksPort, err := allocateLocalPort()
	if err != nil {
		return err
	}

	tmpDir, err := os.MkdirTemp("", "pd-protocol-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	cfg := map[string]any{
		"log": map[string]any{
			"level": "warn",
		},
		"inbounds": []map[string]any{
			{
				"type":        "socks",
				"tag":         "socks-in",
				"listen":      "127.0.0.1",
				"listen_port": socksPort,
			},
		},
		"outbounds": []map[string]any{
			target.outbound,
			{"type": "direct", "tag": "direct"},
		},
		"route": map[string]any{
			"final": "bench",
		},
	}

	cfgBytes, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	cfgPath := filepath.Join(tmpDir, "probe.json")
	if err := os.WriteFile(cfgPath, cfgBytes, 0o600); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, singboxPath, "run", "-c", cfgPath)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return err
	}
	defer stopCommand(cmd)

	if err := waitLocalSOCKSReady(socksPort, localSOCKSReadyTimeout); err != nil {
		return fmt.Errorf("socks not ready: %w", err)
	}

	var lastErr error
	for attempt := 1; attempt <= defaultProtocolProbeAttempts; attempt++ {
		if err := httpProbeViaSOCKS(ctx, socksPort, probeURL, timeout); err == nil {
			return nil
		} else {
			lastErr = err
		}

		if attempt == defaultProtocolProbeAttempts {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(protocolProbeRetryDelay):
		}
	}

	return lastErr
}

func stopCommand(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}

	_ = cmd.Process.Kill()
	waitCh := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(waitCh)
	}()

	select {
	case <-waitCh:
	case <-time.After(2 * time.Second):
	}
}

func waitLocalSOCKSReady(port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))

	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, localSOCKSDialTimeout)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(120 * time.Millisecond)
	}

	return fmt.Errorf("timeout waiting local socks port %d", port)
}

func httpProbeViaSOCKS(ctx context.Context, socksPort int, targetURL string, timeout time.Duration) error {
	socksDialer, err := proxy.SOCKS5("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort)), nil, proxy.Direct)
	if err != nil {
		return err
	}

	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			return socksDialer.Dial(network, addr)
		},
		TLSHandshakeTimeout: timeout,
		IdleConnTimeout:     10 * time.Second,
	}

	client := &http.Client{
		Timeout:   timeout,
		Transport: transport,
	}

	req, err := http.NewRequestWithContext(ctx, "GET", targetURL, nil)
	if err != nil {
		return err
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.CopyN(io.Discard, resp.Body, 512)

	if resp.StatusCode >= 500 {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	return nil
}

func allocateLocalPort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return 0, fmt.Errorf("unexpected listen addr type %T", ln.Addr())
	}
	return addr.Port, nil
}

func normalizeProbeURL(raw, fallback string) string {
	candidate := strings.TrimSpace(raw)
	if candidate == "" {
		return fallback
	}
	u, err := url.Parse(candidate)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return fallback
	}
	scheme := strings.ToLower(strings.TrimSpace(u.Scheme))
	if scheme != "http" && scheme != "https" {
		return fallback
	}
	return candidate
}

func parseProtocolProbeTimeout(extra map[string]string, fallback time.Duration) time.Duration {
	if len(extra) == 0 {
		return fallback
	}
	raw := firstExtraValue(extra,
		"protocolProbeTimeoutSec", "protocol_probe_timeout_sec",
		"readinessProbeTimeoutSec", "readiness_probe_timeout_sec",
	)
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	sec, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || sec <= 0 {
		return fallback
	}
	return time.Duration(sec) * time.Second
}

func parseProtocolRepairAttempts(extra map[string]string, fallback int) int {
	if len(extra) == 0 {
		return fallback
	}
	raw := firstExtraValue(extra,
		"protocolRepairAttempts", "protocol_repair_attempts",
		"readinessRepairAttempts", "readiness_repair_attempts",
	)
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return fallback
	}
	if n < 0 {
		return 0
	}
	if n > 3 {
		return 3
	}
	return n
}

func findSingboxBinary(basePath string) string {
	candidates := singboxBinaryCandidates(basePath, runtime.GOOS)
	if fromEnv := strings.TrimSpace(os.Getenv("PRIVATEDEPLOY_SINGBOX_PATH")); fromEnv != "" {
		candidates = append([]string{fromEnv}, candidates...)
	}

	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}

	if fromPath, err := exec.LookPath("sing-box"); err == nil {
		return fromPath
	}
	return ""
}

func singboxBinaryCandidates(basePath, goos string) []string {
	candidates := make([]string, 0, 5)
	if strings.TrimSpace(basePath) == "" {
		return candidates
	}

	suffix := ""
	if goos == "windows" {
		suffix = ".exe"
	}

	return append(candidates,
		filepath.Join(basePath, "data", "sing-box", "sing-box"+suffix),
		filepath.Join(basePath, "data", "sing-box", "sing-box-latest"+suffix),
		filepath.Join(basePath, "build", "bin", "data", "sing-box", "sing-box"+suffix),
		filepath.Join(basePath, "build", "bin", "data", "sing-box", "sing-box-latest"+suffix),
		filepath.Join(basePath, "test-tools", "sing-box"+suffix),
	)
}

func normalizeRealityPublicKey(value string) string {
	s := strings.TrimSpace(value)
	s = strings.TrimRight(s, "=")
	s = strings.ReplaceAll(s, "+", "-")
	s = strings.ReplaceAll(s, "/", "_")
	return s
}

func firstExtraValue(extra map[string]string, keys ...string) string {
	if len(extra) == 0 {
		return ""
	}
	for _, key := range keys {
		if value, ok := extra[key]; ok {
			if strings.TrimSpace(value) != "" {
				return value
			}
		}
	}
	return ""
}

func parseBoolOrDefault(raw string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	case "":
		return fallback
	default:
		return fallback
	}
}
