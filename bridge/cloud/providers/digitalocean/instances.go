package digitalocean

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

// ListInstances returns all DigitalOcean droplets.
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}

	var result struct {
		Droplets []struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
			Networks struct {
				V4 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v4"`
				V6 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v6"`
			} `json:"networks"`
		} `json:"droplets"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	dirty := false
	seen := make(map[string]struct{}, len(result.Droplets))

	instances := make([]cloud.Instance, 0, len(result.Droplets))
	for _, d := range result.Droplets {
		instanceID := fmt.Sprintf("cloud-do-%d", d.ID)
		instance := cloud.Instance{
			ID:        instanceID,
			Provider:  "digitalocean",
			Label:     d.Name,
			Status:    d.Status,
			Region:    d.Region.Slug,
			Plan:      d.Size.Slug,
			CreatedAt: d.CreatedAt,
		}

		record, ok := records[instanceID]
		if !ok {
			record = cloud.InstanceRecord{}
		}

		for _, net := range d.Networks.V4 {
			if net.Type == "public" {
				instance.IPv4 = net.IPAddress
				if record.IPv4 != instance.IPv4 {
					record.IPv4 = instance.IPv4
					dirty = true
				}
				break
			}
		}

		for _, net := range d.Networks.V6 {
			if net.Type == "public" {
				instance.IPv6 = net.IPAddress
				if record.IPv6 != instance.IPv6 {
					record.IPv6 = instance.IPv6
					dirty = true
				}
				break
			}
		}

		if record.Plan != d.Size.Slug {
			record.Plan = d.Size.Slug
			dirty = true
		}

		// If the local record is incomplete (e.g. lost on a fresh device or a
		// CLI-created node), try to recover the proxy credentials by SSHing in
		// and parsing the droplet's cloud-init user-data. DO's API can't return
		// user-data, so this is the only recovery path. Best-effort.
		if !cloud.HasMinimumProxyConfig(record) && instance.IPv4 != "" {
			if recovered, rok := p.recoverNodeRecordForInstance(ctx, instance.IPv4, record); rok {
				record = recovered
				dirty = true
			}
		}

		if ensureManagedTLSDefaults(&record) {
			dirty = true
		}

		createdAtStr := d.CreatedAt.Format(time.RFC3339)
		if record.CreatedAt != createdAtStr {
			record.CreatedAt = createdAtStr
			dirty = true
		}

		if record.SSPort != 0 {
			instance.SSPort = record.SSPort
		}
		if record.SSPassword != "" {
			instance.SSPassword = record.SSPassword
		}
		if record.HysteriaPort != 0 {
			instance.HysteriaPort = record.HysteriaPort
		}
		if record.HysteriaPassword != "" {
			instance.HysteriaPassword = record.HysteriaPassword
		}
		if record.HysteriaServerName != "" {
			instance.HysteriaServerName = record.HysteriaServerName
		}
		if record.HysteriaInsecure != nil {
			instance.HysteriaInsecure = record.HysteriaInsecure
		}
		if record.VLESSPort != 0 {
			instance.VLESSPort = record.VLESSPort
		}
		if record.VLESSUUID != "" {
			instance.VLESSUUID = record.VLESSUUID
		}
		if record.VLESSPublicKey != "" {
			instance.VLESSPublicKey = record.VLESSPublicKey
		}
		if record.VLESSShortID != "" {
			instance.VLESSShortID = record.VLESSShortID
		}
		if record.VLESSServerName != "" {
			instance.VLESSServerName = record.VLESSServerName
		}
		if record.TrojanPort != 0 {
			instance.TrojanPort = record.TrojanPort
		}
		if record.TrojanPassword != "" {
			instance.TrojanPassword = record.TrojanPassword
		}
		if record.TrojanServerName != "" {
			instance.TrojanServerName = record.TrojanServerName
		}
		if record.TrojanInsecure != nil {
			instance.TrojanInsecure = record.TrojanInsecure
		}
		if record.VLESSRelayPort != 0 {
			instance.VLESSRelayPort = record.VLESSRelayPort
		}

		records[instanceID] = record
		seen[instanceID] = struct{}{}

		instances = append(instances, instance)
	}

	if len(records) > len(seen) {
		for id := range records {
			if _, ok := seen[id]; !ok {
				dirty = true
				delete(records, id)
			}
		}
	}

	if dirty {
		if err := p.saveNodeRecords(records); err != nil {
			return nil, err
		}
	}

	return instances, nil
}

// CreateInstance creates a new DigitalOcean droplet.
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	extra := provutil.MergeExtra(nil, opts.Extra)
	if p.config != nil {
		extra = provutil.MergeExtra(p.config.Extra, opts.Extra)
	}
	tuning := deploy.ResolveDeploymentTuning(extra)
	ports := deploy.AllocatePorts(tuning.PortProfile)
	if tuning.PortProfile == deploy.DefaultPortProfile {
		ports = deploy.PortAssignment{
			SSPort:         23650,
			HysteriaPort:   23651,
			VLESSPort:      23652,
			TrojanPort:     23653,
			VLESSRelayPort: 23654,
		}
	}

	ssPort := ports.SSPort
	ssPassword := deploy.GenerateRandomPassword(16)
	hysteriaPort := ports.HysteriaPort
	hysteriaPassword := deploy.GenerateRandomPassword(22)
	vlessPort := ports.VLESSPort
	vlessUUID := deploy.GenerateUUID()
	trojanPort := ports.TrojanPort
	trojanPassword := deploy.GenerateRandomPassword(22)
	vlessRelayPort := ports.VLESSRelayPort

	realityPrivateKey, realityPublicKey, err := deploy.GenerateRealityKeyPair()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to generate Reality keypair: %v\n", err)
		realityPrivateKey = ""
		realityPublicKey = ""
	}
	realityShortID := provutil.GenerateShortID()

	userData := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
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
	})
	if userData == "" {
		return nil, fmt.Errorf("failed to render deployment script")
	}

	createReq := map[string]interface{}{
		"name":       opts.Label,
		"region":     opts.Region,
		"size":       opts.Plan,
		"image":      "debian-12-x64",
		"user_data":  userData,
		"monitoring": true,
		"ipv6":       true,
	}

	// Always attach PrivateDeploy's managed key so the node stays recoverable
	// (DO can't add keys to a running droplet, nor return user-data later).
	// Best-effort: a key-provisioning failure must not block the deploy.
	sshKeyIDs := []interface{}{}
	if managedID, _, kerr := p.ensureManagedSSHKey(ctx); kerr == nil && managedID != 0 {
		sshKeyIDs = append(sshKeyIDs, managedID)
	}
	if opts.SSHKeyID != "" {
		if keyID, err := strconv.Atoi(opts.SSHKeyID); err == nil {
			sshKeyIDs = append(sshKeyIDs, keyID)
		} else {
			sshKeyIDs = append(sshKeyIDs, opts.SSHKeyID)
		}
	}
	if len(sshKeyIDs) > 0 {
		createReq["ssh_keys"] = sshKeyIDs
	}

	reqBody, err := json.Marshal(createReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/droplets", bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Droplet struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
		} `json:"droplet"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	instanceID := fmt.Sprintf("cloud-do-%d", result.Droplet.ID)

	instance := &cloud.Instance{
		ID:                 instanceID,
		Provider:           "digitalocean",
		Label:              result.Droplet.Name,
		Status:             result.Droplet.Status,
		Region:             result.Droplet.Region.Slug,
		Plan:               result.Droplet.Size.Slug,
		CreatedAt:          result.Droplet.CreatedAt,
		SSPort:             ssPort,
		SSPassword:         ssPassword,
		HysteriaPort:       hysteriaPort,
		HysteriaPassword:   hysteriaPassword,
		HysteriaServerName: tuning.HysteriaServerName,
		HysteriaInsecure:   deploy.BoolPtr(tuning.HysteriaInsecure),
		VLESSPort:          vlessPort,
		VLESSUUID:          vlessUUID,
		VLESSPublicKey:     realityPublicKey,
		VLESSShortID:       realityShortID,
		VLESSServerName:    tuning.VLESSServerName,
		TrojanPort:         trojanPort,
		TrojanPassword:     trojanPassword,
		TrojanServerName:   tuning.TrojanServerName,
		TrojanInsecure:     deploy.BoolPtr(tuning.TrojanInsecure),
		VLESSRelayPort:     vlessRelayPort,
	}

	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	record := cloud.InstanceRecord{
		Plan:               opts.Plan,
		CreatedAt:          result.Droplet.CreatedAt.Format(time.RFC3339),
		SSPort:             ssPort,
		SSPassword:         ssPassword,
		HysteriaPort:       hysteriaPort,
		HysteriaPassword:   hysteriaPassword,
		HysteriaServerName: tuning.HysteriaServerName,
		HysteriaInsecure:   deploy.BoolPtr(tuning.HysteriaInsecure),
		VLESSPort:          vlessPort,
		VLESSUUID:          vlessUUID,
		VLESSPublicKey:     realityPublicKey,
		VLESSShortID:       realityShortID,
		VLESSServerName:    tuning.VLESSServerName,
		TrojanPort:         trojanPort,
		TrojanPassword:     trojanPassword,
		TrojanServerName:   tuning.TrojanServerName,
		TrojanInsecure:     deploy.BoolPtr(tuning.TrojanInsecure),
		VLESSRelayPort:     vlessRelayPort,
	}

	if instance.IPv4 != "" {
		record.IPv4 = instance.IPv4
	}

	if instance.IPv6 != "" {
		record.IPv6 = instance.IPv6
	}

	records[instanceID] = record

	if err := p.saveNodeRecords(records); err != nil {
		return nil, err
	}

	firewallID, err := p.ensurePrivateDeployFirewall(ctx, ports)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to create/get firewall: %v\n", err)
	} else {
		if err := p.associateFirewallWithDroplet(ctx, firewallID, result.Droplet.ID); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to associate firewall with droplet: %v\n", err)
		}
	}

	readyTimeout := provutil.ParseServiceReadyTimeout(extra, defaultServiceReadyTimeout)
	readyPorts := []int{ssPort, vlessPort, trojanPort}
	if readyInstance, waitErr := p.waitForInstanceAndTCPPorts(ctx, instanceID, readyPorts, readyTimeout); waitErr != nil {
		fmt.Fprintf(os.Stderr, "[DigitalOceanProvider] Warning: %v\n", waitErr)
	} else if readyInstance != nil {
		instance = readyInstance
	}

	if probedInstance, probeErr := p.ensureProtocolReadinessWithRepair(ctx, instanceID, result.Droplet.ID, ports, extra); probeErr != nil {
		fmt.Fprintf(os.Stderr, "[DigitalOceanProvider] Warning: protocol readiness check failed: %v\n", probeErr)
	} else if probedInstance != nil {
		instance = probedInstance
	}

	return instance, nil
}

// DestroyInstance destroys a DigitalOcean droplet.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if instanceID == "" {
		return cloud.ErrInstanceNotFound
	}

	// DigitalOcean wants the numeric droplet ID; PrivateDeploy IDs are prefixed.
	actualID := strings.TrimPrefix(instanceID, "cloud-do-")
	if actualID == "" {
		return cloud.ErrInstanceNotFound
	}

	req, err := http.NewRequestWithContext(ctx, "DELETE", baseURL+"/droplets/"+actualID, nil)
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

	if resp.StatusCode == http.StatusNotFound {
		_ = p.deleteNodeRecord(instanceID)
		return nil
	}

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	return p.deleteNodeRecord(instanceID)
}

// GetInstance retrieves a specific DigitalOcean droplet.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	actualID := strings.TrimPrefix(instanceID, "cloud-do-")
	if actualID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+p.config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		_ = p.deleteNodeRecord(instanceID)
		return nil, cloud.ErrInstanceNotFound
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	var result struct {
		Droplet struct {
			ID        int       `json:"id"`
			Name      string    `json:"name"`
			Status    string    `json:"status"`
			CreatedAt time.Time `json:"created_at"`
			Region    struct {
				Slug string `json:"slug"`
			} `json:"region"`
			Size struct {
				Slug string `json:"slug"`
			} `json:"size"`
			Networks struct {
				V4 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v4"`
				V6 []struct {
					IPAddress string `json:"ip_address"`
					Type      string `json:"type"`
				} `json:"v6"`
			} `json:"networks"`
		} `json:"droplet"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	instance := &cloud.Instance{
		ID:        fmt.Sprintf("cloud-do-%d", result.Droplet.ID),
		Provider:  "digitalocean",
		Label:     result.Droplet.Name,
		Status:    result.Droplet.Status,
		Region:    result.Droplet.Region.Slug,
		Plan:      result.Droplet.Size.Slug,
		CreatedAt: result.Droplet.CreatedAt,
	}

	for _, net := range result.Droplet.Networks.V4 {
		if net.Type == "public" {
			instance.IPv4 = net.IPAddress
			break
		}
	}

	for _, net := range result.Droplet.Networks.V6 {
		if net.Type == "public" {
			instance.IPv6 = net.IPAddress
			break
		}
	}

	records, err := p.loadNodeRecords()
	if err == nil {
		record := records[instance.ID]
		updated := false

		if instance.IPv4 != "" && record.IPv4 != instance.IPv4 {
			record.IPv4 = instance.IPv4
			updated = true
		}
		if instance.IPv6 != "" && record.IPv6 != instance.IPv6 {
			record.IPv6 = instance.IPv6
			updated = true
		}
		plan := result.Droplet.Size.Slug
		if record.Plan != plan {
			record.Plan = plan
			updated = true
		}
		createdAtStr := result.Droplet.CreatedAt.Format(time.RFC3339)
		if record.CreatedAt != createdAtStr {
			record.CreatedAt = createdAtStr
			updated = true
		}
		if ensureManagedTLSDefaults(&record) {
			updated = true
		}

		if record.SSPort != 0 {
			instance.SSPort = record.SSPort
		}
		if record.SSPassword != "" {
			instance.SSPassword = record.SSPassword
		}
		if record.HysteriaPort != 0 {
			instance.HysteriaPort = record.HysteriaPort
		}
		if record.HysteriaPassword != "" {
			instance.HysteriaPassword = record.HysteriaPassword
		}
		if record.HysteriaServerName != "" {
			instance.HysteriaServerName = record.HysteriaServerName
		}
		if record.HysteriaInsecure != nil {
			instance.HysteriaInsecure = record.HysteriaInsecure
		}
		if record.VLESSPort != 0 {
			instance.VLESSPort = record.VLESSPort
		}
		if record.VLESSUUID != "" {
			instance.VLESSUUID = record.VLESSUUID
		}
		if record.VLESSPublicKey != "" {
			instance.VLESSPublicKey = record.VLESSPublicKey
		}
		if record.VLESSShortID != "" {
			instance.VLESSShortID = record.VLESSShortID
		}
		if record.VLESSServerName != "" {
			instance.VLESSServerName = record.VLESSServerName
		}
		if record.TrojanPort != 0 {
			instance.TrojanPort = record.TrojanPort
		}
		if record.TrojanPassword != "" {
			instance.TrojanPassword = record.TrojanPassword
		}
		if record.TrojanServerName != "" {
			instance.TrojanServerName = record.TrojanServerName
		}
		if record.TrojanInsecure != nil {
			instance.TrojanInsecure = record.TrojanInsecure
		}
		if record.VLESSRelayPort != 0 {
			instance.VLESSRelayPort = record.VLESSRelayPort
		}

		records[instance.ID] = record
		if updated {
			_ = p.saveNodeRecords(records)
		}
	}

	return instance, nil
}
