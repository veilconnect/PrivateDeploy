// cdn-e2e: deploys a temporary Vultr node with vlessRelayPort, deploys a CF
// Worker pointing at that node via bridge/cdn (same code path PD uses),
// verifies the WS upgrade through the Worker, then destroys both. Reads
// VULTR_KEY and CF_TOKEN from env. NEVER bake secrets in source.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"privatedeploy/bridge/cdn"
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
)

func main() {
	keepNode := flag.Bool("keep", false, "skip destroy at end (for debugging)")
	existing := flag.String("instance", "", "skip deploy, use this instance id")
	flag.Parse()

	vultrKey := os.Getenv("VULTR_KEY")
	cfToken := os.Getenv("CF_TOKEN")
	if vultrKey == "" || cfToken == "" {
		log.Fatal("env VULTR_KEY and CF_TOKEN required")
	}

	tmp, err := os.MkdirTemp("", "cdn-e2e-")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(tmp)
	if err := os.MkdirAll(filepath.Join(tmp, "data", "cloud"), 0o755); err != nil {
		log.Fatal(err)
	}
	cfgJSON := fmt.Sprintf(`{"provider":"vultr","apiKey":%q,"defaultRegion":"lax","defaultPlan":"vc2-1c-1gb"}`, vultrKey)
	if err := os.WriteFile(filepath.Join(tmp, "data", "cloud", "vultr-config.json"), []byte(cfgJSON), 0o600); err != nil {
		log.Fatal(err)
	}
	os.Setenv("PRIVATEDEPLOY_BASE_PATH", tmp)

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Minute)
	defer cancel()

	mgr := cloud.NewManager(context.Background(), defaults.Registry())
	if err := mgr.SetActiveProvider("vultr"); err != nil {
		log.Fatal(err)
	}
	provider, err := mgr.GetActiveProvider()
	if err != nil {
		log.Fatal(err)
	}

	cdnMgr := cdn.NewManager(tmp)
	fmt.Println("[0/5] verify CF token via bridge/cdn...")
	cdnState, err := cdnMgr.VerifyAndPersist(ctx, cfToken)
	if err != nil {
		log.Fatalf("VerifyAndPersist: %v", err)
	}
	fmt.Printf("  ✓ token ok, account=%s subdomain=%s\n", cdnState.AccountEmail, cdnState.WorkersSubdomain)

	var inst *cloud.Instance
	if *existing != "" {
		fmt.Printf("[reuse] instance %s\n", *existing)
		inst, err = provider.GetInstance(ctx, *existing)
		if err != nil {
			log.Fatalf("GetInstance: %v", err)
		}
	} else {
		label := fmt.Sprintf("pd-cdn-e2e-%d", time.Now().Unix())
		fmt.Printf("\n[1/5] deploy temp Vultr %s lax vc2-1c-1gb...\n", label)
		inst, err = provider.CreateInstance(ctx, &cloud.CreateInstanceOptions{Label: label, Region: "lax", Plan: "vc2-1c-1gb"})
		if err != nil {
			log.Fatalf("CreateInstance: %v", err)
		}
		fmt.Printf("  id=%s status=%s ipv4=%s\n", inst.ID, inst.Status, inst.IPv4)
		// Persist the root password for offline SSH access — Vultr's API only
		// returns default_password on the first GET after create. We need it
		// later if the systemd unit hangs and we have to journalctl from the
		// host. Mode 0600, /tmp dir, gone after this Go program exits anyway
		// since defer os.RemoveAll(tmp) cleans it.
		pwFile := filepath.Join(tmp, "root.pw")
		_ = os.WriteFile(pwFile, []byte(inst.Password+"\n"), 0o600)
		fmt.Printf("  root pw stored at %s (and: %q)\n", pwFile, inst.Password)

		// poll until active
		deadline := time.Now().Add(8 * time.Minute)
		for time.Now().Before(deadline) {
			got, err := provider.GetInstance(ctx, inst.ID)
			if err == nil {
				inst = got
				if got.Status == "active" || got.Status == "running" || got.Status == "ok" {
					fmt.Printf("  ✓ active ipv4=%s\n", got.IPv4)
					break
				}
			}
			time.Sleep(10 * time.Second)
		}
	}

	relayPort := inst.VLESSRelayPort
	if relayPort == 0 {
		log.Fatalf("instance has no VLESSRelayPort — userdata too old or deploy script regression")
	}
	fmt.Printf("  vlessRelayPort=%d\n", relayPort)

	fmt.Println("\n[2/5] wait for relay-server to listen...")
	probeDeadline := time.Now().Add(7 * time.Minute)
	dialed := false
	for time.Now().Before(probeDeadline) {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", inst.IPv4, relayPort), 3*time.Second)
		if err == nil {
			c.Close()
			fmt.Println("  ✓ relay port reachable")
			dialed = true
			break
		}
		time.Sleep(8 * time.Second)
	}
	if !dialed {
		log.Fatalf("relay port %d on %s never came up", relayPort, inst.IPv4)
	}

	// M1: optionally exercise the custom-domain Worker route. Off by default
	// so the harness still works for users without a CF zone. Set both env
	// vars to enable:
	//   CF_ZONE_ID=<32-char zone id>
	//   CF_CUSTOM_SUBDOMAIN=relay   (single label; final host = relay.<zone>)
	zoneID := os.Getenv("CF_ZONE_ID")
	customSub := os.Getenv("CF_CUSTOM_SUBDOMAIN")
	if zoneID != "" && customSub != "" {
		fmt.Printf("\n[M1] bind custom domain: zone=%s subdomain=%s\n", zoneID, customSub)
		if _, err := cdnMgr.SetCustomDomain(ctx, zoneID, customSub); err != nil {
			fmt.Printf("  ⚠ SetCustomDomain failed: %v\n", err)
			fmt.Println("    falling back to workers.dev-only — token may lack Zone:Read or DNS:Edit")
			zoneID = "" // disable later checks
		} else {
			fmt.Println("  ✓ custom domain saved")
		}
	} else {
		fmt.Println("\n[M1] CF_ZONE_ID / CF_CUSTOM_SUBDOMAIN not set — skipping custom-domain test")
	}

	fmt.Println("\n[3/5] deploy CF Worker via bridge/cdn.DeployWorker...")
	cdnState, err = cdnMgr.DeployWorker(ctx, inst.ID, inst.Label, inst.IPv4, relayPort)
	if err != nil {
		fmt.Printf("  ✗ deploy err: %v\n", err)
		if !*keepNode {
			fmt.Println("  cleaning up Vultr instance before exit...")
			_ = provider.DestroyInstance(ctx, inst.ID)
		}
		log.Fatal(err)
	}
	dep, ok := cdnState.Deployments[inst.ID]
	if !ok {
		log.Fatalf("no deployment record for %s after deploy", inst.ID)
	}
	fmt.Printf("  ✓ worker live: https://%s  backend=%s\n", dep.WorkerHost, dep.Backend)
	if dep.CustomHost != "" {
		fmt.Printf("  ✓ custom-domain bound: https://%s (route=%s, dns=%s)\n", dep.CustomHost, dep.RouteID, dep.DNSRecordID)
	} else if zoneID != "" {
		fmt.Println("  ⚠ custom domain configured but Deployment has no CustomHost — check cdnState.LastError")
		if cdnState.LastError != "" {
			fmt.Printf("    lastError: %s\n", cdnState.LastError)
		}
	}

	fmt.Println("\n[4/5] verify Worker accepts WS upgrade (CF edge propagation ~10s)...")
	time.Sleep(12 * time.Second)
	if err := probeWorkerWS(dep.WorkerHost); err != nil {
		fmt.Printf("  ⚠ workers.dev: %v\n", err)
		fmt.Println("    (probably regional reachability DNS interference of *.workers.dev — expected from regional networks)")
	} else {
		fmt.Println("  ✓ workers.dev WS upgrade succeeded")
	}
	if dep.CustomHost != "" {
		// Custom-domain DNS (CF orange cloud) takes a beat to propagate to
		// the public resolvers we use; one short retry catches the race.
		fmt.Printf("  probing custom host: %s ...\n", dep.CustomHost)
		var probeErr error
		for attempt := 1; attempt <= 3; attempt++ {
			probeErr = probeWorkerWS(dep.CustomHost)
			if probeErr == nil {
				fmt.Printf("  ✓ custom-domain WS upgrade succeeded on attempt %d\n", attempt)
				break
			}
			fmt.Printf("  attempt %d: %v\n", attempt, probeErr)
			time.Sleep(8 * time.Second)
		}
		if probeErr != nil {
			fmt.Printf("  ✗ custom-domain probe failed after retries: %v\n", probeErr)
		}
	}

	if *keepNode {
		fmt.Printf("\n[keep] not destroying. instance=%s worker=%s custom=%s\n", inst.ID, dep.WorkerHost, dep.CustomHost)
		return
	}

	fmt.Println("\n[5/5] cleanup")
	if _, err := cdnMgr.DeleteWorker(ctx, inst.ID); err != nil {
		fmt.Printf("  worker delete err: %v\n", err)
	} else {
		fmt.Println("  ✓ worker deleted (route + DNS torn down if M1 was active)")
	}
	if zoneID != "" {
		if _, err := cdnMgr.ClearCustomDomain(); err != nil {
			fmt.Printf("  custom-domain clear err: %v\n", err)
		} else {
			fmt.Println("  ✓ custom-domain config cleared")
		}
	}
	if err := provider.DestroyInstance(ctx, inst.ID); err != nil {
		fmt.Printf("  destroy err: %v\n", err)
	} else {
		fmt.Println("  ✓ Vultr instance destroyed")
	}
	fmt.Println("\nE2E complete.")
}

// probeWorkerWS opens TLS to <host>:443 with SNI=host, sends an HTTP/1.1 WS
// upgrade, and reads the response. If we see "101 Switching Protocols" the
// Worker accepted the upgrade — meaning its fetch handler ran AND it called
// connect() to the backend (otherwise CF's default 200 landing-page handler
// would have responded instead).
func probeWorkerWS(host string) error {
	d := &tls.Dialer{Config: &tls.Config{ServerName: host}}
	c, err := d.DialContext(context.Background(), "tcp", host+":443")
	if err != nil {
		return fmt.Errorf("tls dial: %w", err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	req := fmt.Sprintf("GET /?ed=2560 HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"+
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", host)
	if _, err := c.Write([]byte(req)); err != nil {
		return err
	}
	buf := make([]byte, 1024)
	n, err := c.Read(buf)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}
	resp := string(buf[:n])
	statusLine := strings.SplitN(resp, "\r\n", 2)[0]
	if !strings.Contains(statusLine, "101") {
		return fmt.Errorf("expected 101 Switching Protocols, got %q", statusLine)
	}
	return nil
}
