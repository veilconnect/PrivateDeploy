package digitalocean

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

type digitalOceanCreateOperationData struct {
	Record nodeRecord            `json:"record"`
	Ports  deploy.PortAssignment `json:"ports"`
}

type digitalOceanTaggedDroplet struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	Tags      []string  `json:"tags"`
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
}

// ReconcileCreateOperation recovers exactly one tagged droplet and its
// pre-POST credentials. There is intentionally no create request in this
// function; an absent marker remains a pending outcome.
func (p *Provider) ReconcileCreateOperation(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil || strings.TrimSpace(opts.OperationID) == "" || strings.TrimSpace(opts.OperationJournalPath) == "" {
		return nil, fmt.Errorf("DigitalOcean create reconciliation requires a durable operation journal")
	}
	var prepared digitalOceanCreateOperationData
	record, err := cloud.LoadCreateOperationProviderData(opts.OperationJournalPath, &prepared)
	if err != nil {
		return nil, err
	}
	if record.State == cloud.CreateOperationPending || record.State == cloud.CreateOperationPrepared {
		return nil, fmt.Errorf("DigitalOcean operation ended before the create submission boundary")
	}
	wantTag := cloud.CreateOperationTag("digitalocean", opts.OperationID)
	if record.OperationTag != wantTag {
		return nil, fmt.Errorf("DigitalOcean operation marker mismatch")
	}

	apiKey, err := p.apiKey()
	if err != nil {
		return nil, fmt.Errorf("%w: DigitalOcean marker query has no usable credentials: %v", cloud.ErrCreateOutcomePending, err)
	}
	queryURL := baseURL + "/droplets?per_page=200&tag_name=" + url.QueryEscape(wantTag)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: DigitalOcean marker query failed: %v", cloud.ErrCreateOutcomePending, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("%w: DigitalOcean marker query status %d: %s", cloud.ErrCreateOutcomePending, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var payload struct {
		Droplets []digitalOceanTaggedDroplet `json:"droplets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("%w: DigitalOcean marker response could not be decoded: %v", cloud.ErrCreateOutcomePending, err)
	}
	matches := make([]digitalOceanTaggedDroplet, 0, 1)
	for _, droplet := range payload.Droplets {
		for _, tag := range droplet.Tags {
			if tag == wantTag {
				matches = append(matches, droplet)
				break
			}
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("%w: no DigitalOcean droplet with operation marker %s is visible yet", cloud.ErrCreateOutcomePending, wantTag)
	}
	if len(matches) != 1 {
		return nil, fmt.Errorf("DigitalOcean operation marker %s matched %d droplets; refusing to guess", wantTag, len(matches))
	}

	remote := matches[0]
	if remote.ID == 0 {
		return nil, fmt.Errorf("%w: tagged DigitalOcean response had no droplet id", cloud.ErrCreateOutcomePending)
	}
	instanceID := fmt.Sprintf("cloud-do-%d", remote.ID)
	p.beginInstanceCreate(instanceID)
	defer p.endInstanceCreate(instanceID)

	recovered := prepared.Record
	if remote.Size.Slug != "" {
		recovered.Plan = remote.Size.Slug
	}
	if !remote.CreatedAt.IsZero() {
		recovered.CreatedAt = remote.CreatedAt.Format(time.RFC3339)
	}
	for _, network := range remote.Networks.V4 {
		if network.Type == "public" {
			recovered.IPv4 = network.IPAddress
			break
		}
	}
	for _, network := range remote.Networks.V6 {
		if network.Type == "public" {
			recovered.IPv6 = network.IPAddress
			break
		}
	}

	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if existing, ok := records[instanceID]; ok {
			recovered.FirewallGroupID = existing.FirewallGroupID
			recovered.FirewallOwnershipToken = existing.FirewallOwnershipToken
			recovered.FirewallCleanupPending = false
			if existing.LastDeployWarning != "" {
				recovered.LastDeployWarning = existing.LastDeployWarning
			}
		}
		records[instanceID] = recovered
		return true, nil
	}); err != nil {
		return nil, fmt.Errorf("%w: tagged DigitalOcean droplet %s was found but credentials could not be restored: %v", cloud.ErrCreateOutcomePending, instanceID, err)
	}

	if err := cloud.MarkCreateOperationRemote(opts.OperationJournalPath, instanceID); err != nil {
		return nil, fmt.Errorf("%w: tagged DigitalOcean droplet %s was restored but its id was not journaled: %v", cloud.ErrCreateOutcomePending, instanceID, err)
	}
	instance := digitalOceanRecoveredInstance(remote, recovered)
	return &instance, nil
}

func digitalOceanRecoveredInstance(remote digitalOceanTaggedDroplet, record nodeRecord) cloud.Instance {
	instance := cloud.Instance{
		ID:                 fmt.Sprintf("cloud-do-%d", remote.ID),
		Provider:           "digitalocean",
		Label:              remote.Name,
		Status:             remote.Status,
		Region:             remote.Region.Slug,
		Plan:               remote.Size.Slug,
		IPv4:               record.IPv4,
		IPv6:               record.IPv6,
		CreatedAt:          remote.CreatedAt,
		Port:               record.Port,
		Password:           record.Password,
		SSPort:             record.SSPort,
		SSPassword:         record.SSPassword,
		HysteriaPort:       record.HysteriaPort,
		HysteriaPassword:   record.HysteriaPassword,
		HysteriaServerName: record.HysteriaServerName,
		HysteriaInsecure:   record.HysteriaInsecure,
		VLESSPort:          record.VLESSPort,
		VLESSUUID:          record.VLESSUUID,
		VLESSPublicKey:     record.VLESSPublicKey,
		VLESSShortID:       record.VLESSShortID,
		VLESSServerName:    record.VLESSServerName,
		TrojanPort:         record.TrojanPort,
		TrojanPassword:     record.TrojanPassword,
		TrojanServerName:   record.TrojanServerName,
		TrojanInsecure:     record.TrojanInsecure,
		VLESSRelayPort:     record.VLESSRelayPort,
		LastDeployWarning:  record.LastDeployWarning,
	}
	return instance
}

var _ cloud.CreateOperationReconciler = (*Provider)(nil)

// FinalizeReconciledCreate attaches the deterministic firewall and performs a
// bounded readiness/self-heal pass on the recovered droplet. It never creates
// a droplet. Residual readiness is a durable node warning, not a fake healthy
// completion.
func (p *Provider) FinalizeReconciledCreate(ctx context.Context, _ *cloud.CreateInstanceOptions, instance *cloud.Instance) (*cloud.Instance, error) {
	if instance == nil || strings.TrimSpace(instance.ID) == "" {
		return nil, cloud.ErrInstanceNotFound
	}
	dropletID, err := strconv.Atoi(strings.TrimPrefix(instance.ID, "cloud-do-"))
	if err != nil || dropletID <= 0 {
		return nil, cloud.ErrInstanceNotFound
	}
	ports := digitalOceanPortsFromInstance(instance)
	warnings := make([]string, 0, 2)
	if ports.SSPort <= 0 {
		warnings = append(warnings, "instance/TCP readiness failed: restored node has no managed Shadowsocks port")
	} else if err := p.configureInstanceFirewall(ctx, instance.ID, dropletID, ports); err != nil {
		warnings = append(warnings, fmt.Sprintf("DigitalOcean firewall reconciliation failed: %v", err))
	}

	readyPorts := provutil.UniquePositivePorts([]int{ports.SSPort, ports.VLESSPort, ports.TrojanPort})
	if ports.SSPort > 0 {
		pending := provutil.PendingTCPPortsContext(ctx, instance.IPv4, readyPorts, time.Second)
		readinessWarning := ""
		if len(pending) > 0 && strings.TrimSpace(instance.IPv4) != "" &&
			(strings.EqualFold(instance.Status, "active") || strings.EqualFold(instance.Status, "running")) {
			if rebootErr := p.rebootDroplet(ctx, dropletID); rebootErr != nil {
				readinessWarning = fmt.Sprintf("instance/TCP readiness failed: pending ports %s; in-place reboot failed: %v", provutil.PortsToCSV(pending), rebootErr)
			} else {
				select {
				case <-ctx.Done():
					readinessWarning = fmt.Sprintf("instance/TCP readiness failed: %v", ctx.Err())
				case <-time.After(2 * time.Second):
					pending = provutil.PendingTCPPortsContext(ctx, instance.IPv4, readyPorts, time.Second)
				}
			}
		}
		if len(pending) > 0 && readinessWarning == "" {
			readinessWarning = fmt.Sprintf("instance/TCP readiness failed: pending ports %s", provutil.PortsToCSV(pending))
		}
		if readinessWarning != "" {
			warnings = append(warnings, readinessWarning)
		}
	}

	warning := strings.Join(warnings, "; ")
	if err := p.setDeployWarning(instance.ID, warning); err != nil {
		return nil, fmt.Errorf("persist reconciled DigitalOcean finalization result: %w", err)
	}
	finalized := *instance
	finalized.LastDeployWarning = warning
	return &finalized, nil
}

var _ cloud.ReconciledCreateFinalizer = (*Provider)(nil)
