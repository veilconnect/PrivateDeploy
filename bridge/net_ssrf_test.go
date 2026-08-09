package bridge

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"privatedeploy/bridge/services/filesystem"
)

func clearProxyEnvironment(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
		"ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
	} {
		t.Setenv(key, "")
	}
}

func TestValidateOutboundURL(t *testing.T) {
	blocked := []string{
		"http://127.0.0.1/",
		"http://localhost:8080/x",
		"http://metadata.google.internal/computeMetadata/v1/",
		"http://printer.office.lan/admin",
		"https://169.254.169.254/latest/meta-data/",
		"http://10.0.0.5/",
		"http://192.168.1.1/",
		"http://172.16.0.1/",
		"http://[::1]/",
		"ftp://example.com/",
		"file:///etc/passwd",
		"http://0.0.0.0/",
		"",
	}
	for _, u := range blocked {
		if err := validateOutboundURL(u); err == nil {
			t.Errorf("expected %q to be blocked", u)
		}
	}

	allowed := []string{
		"https://speed.cloudflare.com/__down?bytes=1000000",
		"https://api.vultr.com/v2/instances",
		"http://example.com:8443/path",
	}
	for _, u := range allowed {
		if err := validateOutboundURL(u); err != nil {
			t.Errorf("expected %q to be allowed, got %v", u, err)
		}
	}
}

func TestDownloadRejectsOutsideAndRootPathsBeforeNetwork(t *testing.T) {
	basePath := t.TempDir()
	app := &App{FileService: filesystem.NewService(basePath)}
	for _, target := range []string{filepath.Join(t.TempDir(), "outside.bin"), ".", "../../outside.bin"} {
		result := app.Download(
			http.MethodGet,
			"https://host-that-must-not-be-contacted.invalid/file",
			target,
			nil,
			"",
			RequestOptions{},
		)
		if result.Flag || result.Status != http.StatusBadRequest {
			t.Fatalf("Download(%q) = %+v, want fail-fast status 400", target, result)
		}
	}
}

func TestUploadRejectsOutsideAndRootPathsBeforeNetwork(t *testing.T) {
	basePath := t.TempDir()
	app := &App{FileService: filesystem.NewService(basePath)}
	for _, source := range []string{filepath.Join(t.TempDir(), "outside.bin"), ".", "../../outside.bin"} {
		result := app.Upload(
			http.MethodPost,
			"https://host-that-must-not-be-contacted.invalid/upload",
			source,
			nil,
			"",
			RequestOptions{FileField: "file"},
		)
		if result.Flag || result.Status != http.StatusBadRequest {
			t.Fatalf("Upload(%q) = %+v, want fail-fast status 400", source, result)
		}
	}
}

func TestRedactedRequestURLRemovesCredentialsPathAndParameters(t *testing.T) {
	got := redactedRequestURL("https://alice:secret@example.com/subscription/private-token?key=api-secret#fragment")
	if got != "https://example.com/redacted" {
		t.Fatalf("redactedRequestURL() = %q", got)
	}
	for _, secret := range []string{"alice", "secret", "private-token", "api-secret", "fragment"} {
		if strings.Contains(got, secret) {
			t.Fatalf("redacted URL leaked %q: %s", secret, got)
		}
	}
}

func TestRedactedNetworkErrorRemovesOriginalCredentialURL(t *testing.T) {
	raw := "https://alice:secret@example.com/private-token?api_key=hidden"
	got := redactedNetworkError(&url.Error{
		Op:  "Get",
		URL: raw,
		Err: &net.OpError{Op: "dial", Net: "tcp", Err: fmt.Errorf("request %s failed", raw)},
	}, raw)
	for _, secret := range []string{"alice", "secret", "private-token", "hidden"} {
		if strings.Contains(got, secret) {
			t.Fatalf("redacted network error leaked %q: %s", secret, got)
		}
	}
}

func TestRedactedNetworkErrorRemovesProxyCredentials(t *testing.T) {
	proxy := "http://proxy-user:proxy-secret@127.0.0.1:7890"
	got := redactedNetworkError(fmt.Errorf("proxyconnect tcp: %s refused", proxy), proxy)
	for _, secret := range []string{"proxy-user", "proxy-secret"} {
		if strings.Contains(got, secret) {
			t.Fatalf("redacted network error leaked proxy credential %q: %s", secret, got)
		}
	}
}

func TestProxyPinnedTransportRejectsHTTPSProxyWithoutCredentialLeak(t *testing.T) {
	proxyURL, err := url.Parse("https://proxy-user:proxy-secret@proxy.example.test:8443")
	if err != nil {
		t.Fatal(err)
	}
	transport := &proxyPinnedTransport{base: &http.Transport{Proxy: http.ProxyURL(proxyURL)}}
	req, err := http.NewRequest(http.MethodGet, "https://example.com/private-token", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = transport.RoundTrip(req)
	if err == nil {
		t.Fatal("expected HTTPS proxy to fail closed")
	}
	for _, secret := range []string{"proxy-user", "proxy-secret", "private-token"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("HTTPS proxy rejection leaked %q: %s", secret, err)
		}
	}
}

func TestCloneRequestWithPinnedTargetPreservesAuthorityAndSecretPath(t *testing.T) {
	req, err := http.NewRequestWithContext(
		context.Background(),
		http.MethodGet,
		"https://downloads.example.test:8443/private/token?key=secret",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	pinned := cloneRequestWithPinnedTarget(req, "203.0.113.25:8443")
	if pinned.URL.Host != "203.0.113.25:8443" {
		t.Fatalf("pinned URL host = %q", pinned.URL.Host)
	}
	if pinned.Host != "downloads.example.test:8443" {
		t.Fatalf("preserved HTTP authority = %q", pinned.Host)
	}
	if pinned.URL.Path != "/private/token" || pinned.URL.RawQuery != "key=secret" {
		t.Fatalf("request semantics changed while pinning: %s", pinned.URL.String())
	}
	if req.URL.Host != "downloads.example.test:8443" {
		t.Fatalf("original request was mutated: %s", req.URL.String())
	}
}

func TestSSRFSafeControlBlocksInternalIP(t *testing.T) {
	if err := ssrfSafeControl("tcp", "169.254.169.254:80", nil); err == nil {
		t.Fatal("expected metadata IP dial to be blocked")
	}
	if err := ssrfSafeControl("tcp", "10.1.2.3:443", nil); err == nil {
		t.Fatal("expected private IP dial to be blocked")
	}
	if err := ssrfSafeControl("tcp", "1.1.1.1:443", nil); err != nil {
		t.Fatalf("expected public IP dial to be allowed, got %v", err)
	}
}

func TestValidateProxyURL(t *testing.T) {
	allowed := []string{
		"socks5://127.0.0.1:7890",
		"http://localhost:8080",
		"http://1.1.1.1:3128",
	}
	for _, u := range allowed {
		if err := validateProxyURL(u); err != nil {
			t.Errorf("expected proxy %q allowed, got %v", u, err)
		}
	}
	blocked := []string{
		"http://192.168.1.1:3128",
		"socks5://169.254.169.254:1080",
		"http://10.0.0.1:8080",
	}
	for _, u := range blocked {
		if err := validateProxyURL(u); err == nil {
			t.Errorf("expected proxy %q blocked", u)
		}
	}
}

func TestMakeSSRFControlAllowsOnlyConfiguredProxy(t *testing.T) {
	// Explicit loopback proxy: its exact endpoint is dialable, but any other
	// loopback/internal target (e.g. a rebinding host hitting a different port)
	// is still blocked.
	clearProxyEnvironment(t)
	_, allowed, err := resolveProxy(context.Background(), "http://127.0.0.1:7890")
	if err != nil {
		t.Fatal(err)
	}
	control := makeSSRFControl(allowed)

	if err := control("tcp", "127.0.0.1:7890", nil); err != nil {
		t.Fatalf("configured proxy endpoint must be dialable, got %v", err)
	}
	if err := control("tcp", "127.0.0.1:9999", nil); err == nil {
		t.Fatal("a different loopback port must be blocked")
	}
	if err := control("tcp", "169.254.169.254:80", nil); err == nil {
		t.Fatal("metadata must be blocked even with a proxy configured")
	}
	if err := control("tcp", "1.1.1.1:443", nil); err != nil {
		t.Fatalf("public target must be allowed, got %v", err)
	}
}

func TestMakeSSRFControlAllowsLocalhostHostnameProxy(t *testing.T) {
	// A proxy given by the "localhost" alias must be dialable: the Control hook
	// sees the resolved loopback IP, not the hostname, so its IPv4/IPv6 loopback
	// resolutions have to be permitted too. Other loopback ports stay blocked.
	clearProxyEnvironment(t)
	_, allowed, err := resolveProxy(context.Background(), "http://localhost:7890")
	if err != nil {
		t.Fatal(err)
	}
	control := makeSSRFControl(allowed)

	for _, addr := range []string{"127.0.0.1:7890", "[::1]:7890"} {
		if err := control("tcp", addr, nil); err != nil {
			t.Fatalf("localhost proxy resolution %s must be dialable, got %v", addr, err)
		}
	}
	if err := control("tcp", "127.0.0.1:9999", nil); err == nil {
		t.Fatal("a different loopback port must still be blocked")
	}
}

func TestMakeSSRFControlNoProxyBlocksLoopback(t *testing.T) {
	// No explicit proxy and (assuming) no env proxy → loopback is blocked,
	// closing the NO_PROXY / unparseable-proxy rebinding gap.
	clearProxyEnvironment(t)
	if _, _, err := resolveProxy(context.Background(), "not a valid proxy url ::::"); err == nil {
		t.Fatal("malformed explicit proxy must fail closed instead of inheriting environment")
	}
}

func TestRendererNetworkPathsRejectPrivateExplicitProxyBeforeOtherWork(t *testing.T) {
	clearProxyEnvironment(t)
	basePath := t.TempDir()
	app := &App{FileService: filesystem.NewService(basePath)}
	const proxy = "http://proxy-user:proxy-secret@169.254.169.254:80"
	options := RequestOptions{Proxy: proxy, FileField: "file"}

	results := map[string]HTTPResult{
		"requests": app.Requests(http.MethodGet, "https://target-that-must-not-resolve.invalid/private", nil, "", options),
		"download": app.Download(http.MethodGet, "https://target-that-must-not-resolve.invalid/private", filepath.Join(t.TempDir(), "outside.bin"), nil, "", options),
		"upload":   app.Upload(http.MethodPost, "https://target-that-must-not-resolve.invalid/private", filepath.Join(t.TempDir(), "missing.bin"), nil, "", options),
	}
	for name, result := range results {
		if result.Flag || result.Status != http.StatusBadRequest {
			t.Fatalf("%s private proxy result = %+v, want fail-closed 400", name, result)
		}
		message := result.Body
		if !strings.Contains(strings.ToLower(message), "proxy") {
			t.Fatalf("%s error did not identify proxy rejection: %q", name, message)
		}
		for index, secret := range []string{"proxy-user", "proxy-secret", "target-that-must-not-resolve"} {
			if strings.Contains(message, secret) {
				t.Fatalf("%s proxy rejection leaked test credential #%d", name, index+1)
			}
		}
	}
}

func TestEnvironmentProxyCannotWhitelistPrivateEndpoint(t *testing.T) {
	clearProxyEnvironment(t)
	t.Setenv("HTTP_PROXY", "http://env-user:env-secret@10.23.45.67:3128")
	_, _, err := resolveProxy(context.Background(), "")
	if err == nil {
		t.Fatal("private HTTP_PROXY endpoint was accepted")
	}
	for index, secret := range []string{"env-user", "env-secret"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("environment proxy error leaked test credential #%d", index+1)
		}
	}
}

func TestEnvironmentLoopbackProxyIsPreciselyWhitelisted(t *testing.T) {
	clearProxyEnvironment(t)
	t.Setenv("HTTPS_PROXY", "http://localhost:7890")
	_, allowed, err := resolveProxy(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	control := makeSSRFControl(allowed)
	if err := control("tcp", "127.0.0.1:7890", nil); err != nil {
		t.Fatalf("configured loopback proxy was blocked: %v", err)
	}
	if err := control("tcp", "127.0.0.1:7891", nil); err == nil {
		t.Fatal("unconfigured loopback endpoint was allowed")
	}
	if err := control("tcp", "10.23.45.67:7890", nil); err == nil {
		t.Fatal("private endpoint sharing the proxy port was allowed")
	}
}

func TestPublicProxyCannotRebindToLoopback(t *testing.T) {
	clearProxyEnvironment(t)
	_, allowed, err := resolveProxy(context.Background(), "http://1.1.1.1:7890")
	if err != nil {
		t.Fatal(err)
	}
	control := makeSSRFControl(allowed)
	if err := control("tcp", "127.0.0.1:7890", nil); err == nil {
		t.Fatal("public proxy endpoint was allowed to rebind to loopback")
	}
}

func TestRedirectToInternalAddressFailsWithoutCredentialLeak(t *testing.T) {
	clearProxyEnvironment(t)
	client, _, cancel, err := withRequestOptionsClient(RequestOptions{Redirect: true})
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()

	const source = "https://alice:source-secret@example.com/private-token?api_key=hidden"
	const redirected = "http://169.254.169.254/latest/meta-data/?token=redirect-secret"
	redirectRequest, err := http.NewRequest(http.MethodGet, redirected, nil)
	if err != nil {
		t.Fatal(err)
	}
	via, err := http.NewRequest(http.MethodGet, source, nil)
	if err != nil {
		t.Fatal(err)
	}
	redirectErr := client.CheckRedirect(redirectRequest, []*http.Request{via})
	if redirectErr == nil {
		t.Fatal("redirect to metadata endpoint was accepted")
	}
	safe := redactedNetworkError(&url.Error{Op: "Get", URL: redirected, Err: redirectErr}, source, redirected)
	for index, secret := range []string{"alice", "source-secret", "private-token", "hidden", "redirect-secret", "latest/meta-data"} {
		if strings.Contains(safe, secret) {
			t.Fatalf("redirect rejection leaked test credential #%d", index+1)
		}
	}
}

func TestCGNATAndBroadcastBlocked(t *testing.T) {
	for _, s := range []string{"100.64.0.1", "100.127.255.254", "255.255.255.255"} {
		if !isBlockedDialIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be blocked", s)
		}
	}
	if isBlockedDialIP(net.ParseIP("100.63.255.255")) {
		t.Error("100.63.255.255 is public, should not be blocked")
	}
}
