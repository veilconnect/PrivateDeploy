package vultr

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

// vultrCreateOperationData is encrypted into the shared operation journal
// before the first POST. It is sufficient to recreate the local node record
// (including every client credential) when the HTTP response is lost.
type vultrCreateOperationData struct {
	Record  nodeRecord `json:"record"`
	PlanRAM int        `json:"planRam"`
}

// ReconcileCreateOperation queries Vultr by the exact hashed operation tag.
// It deliberately contains no POST path: zero matches remain pending and two
// matches fail closed instead of creating or guessing another billed server.
func (p *Provider) ReconcileCreateOperation(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil || strings.TrimSpace(opts.OperationID) == "" || strings.TrimSpace(opts.OperationJournalPath) == "" {
		return nil, fmt.Errorf("Vultr create reconciliation requires a durable operation journal")
	}
	var prepared vultrCreateOperationData
	record, err := cloud.LoadCreateOperationProviderData(opts.OperationJournalPath, &prepared)
	if err != nil {
		return nil, err
	}
	if record.State == cloud.CreateOperationPending || record.State == cloud.CreateOperationPrepared {
		return nil, fmt.Errorf("Vultr operation ended before the create submission boundary")
	}
	wantTag := cloud.CreateOperationTag("vultr", opts.OperationID)
	if record.OperationTag != wantTag {
		return nil, fmt.Errorf("Vultr operation marker mismatch")
	}

	path := "/instances?per_page=100&tag=" + url.QueryEscape(wantTag)
	response, err := p.apiRequest(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: Vultr marker query failed: %v", cloud.ErrCreateOutcomePending, err)
	}
	var payload struct {
		Instances []vultrInstance `json:"instances"`
	}
	if err := p.parseResponse(response, &payload); err != nil {
		return nil, fmt.Errorf("%w: Vultr marker query was inconclusive: %v", cloud.ErrCreateOutcomePending, err)
	}
	matches := make([]vultrInstance, 0, 1)
	for _, instance := range payload.Instances {
		for _, tag := range instance.Tags {
			if tag == wantTag {
				matches = append(matches, instance)
				break
			}
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("%w: no Vultr instance with operation marker %s is visible yet", cloud.ErrCreateOutcomePending, wantTag)
	}
	if len(matches) != 1 {
		return nil, fmt.Errorf("Vultr operation marker %s matched %d instances; refusing to guess", wantTag, len(matches))
	}

	remote := matches[0]
	if strings.TrimSpace(remote.ID) == "" {
		return nil, fmt.Errorf("%w: tagged Vultr response had no instance id", cloud.ErrCreateOutcomePending)
	}
	p.beginInstanceCreate(remote.ID)
	defer p.endInstanceCreate(remote.ID)

	recovered := prepared.Record
	recovered.InstanceID = remote.ID
	if remote.Label != "" {
		recovered.Label = remote.Label
	}
	if remote.Region != "" {
		recovered.Region = remote.Region
	}
	if remote.Plan != "" {
		recovered.Plan = remote.Plan
	}
	if remote.MainIP != "" {
		recovered.IPv4 = remote.MainIP
	}
	if remote.V6MainIP != "" {
		recovered.IPv6 = remote.V6MainIP
	}
	if remote.CreatedAt != "" {
		recovered.CreatedAt = remote.CreatedAt
	}

	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if existing, ok := records[remote.ID]; ok {
			// A prior recovery attempt may already own a firewall group. Preserve
			// its deletion proof while restoring journaled credentials.
			recovered.FirewallGroupID = existing.FirewallGroupID
			recovered.FirewallOwnershipToken = existing.FirewallOwnershipToken
			recovered.FirewallCleanupPending = false
			if existing.LastDeployWarning != "" {
				recovered.LastDeployWarning = existing.LastDeployWarning
			}
		}
		records[remote.ID] = recovered
		return true, nil
	}); err != nil {
		return nil, fmt.Errorf("%w: tagged Vultr instance %s was found but credentials could not be restored: %v", cloud.ErrCreateOutcomePending, remote.ID, err)
	}

	if err := cloud.MarkCreateOperationRemote(opts.OperationJournalPath, remote.ID); err != nil {
		return nil, fmt.Errorf("%w: tagged Vultr instance %s was restored but its id was not journaled: %v", cloud.ErrCreateOutcomePending, remote.ID, err)
	}
	instance := toCloudInstance(remote, recovered)
	return &instance, nil
}

var _ cloud.CreateOperationReconciler = (*Provider)(nil)

// FinalizeReconciledCreate is intentionally separate from the read-only tag
// lookup above. It converges the instance-owned firewall, performs a bounded
// readiness check and may reboot only that same VPS once. A non-fatal
// readiness concern is persisted on the node before the bridge marks the
// operation succeeded.
func (p *Provider) FinalizeReconciledCreate(ctx context.Context, _ *cloud.CreateInstanceOptions, instance *cloud.Instance) (*cloud.Instance, error) {
	if instance == nil || strings.TrimSpace(instance.ID) == "" {
		return nil, cloud.ErrInstanceNotFound
	}
	ports := vultrPortsFromInstance(instance)
	warnings := make([]string, 0, 2)
	if ports.SSPort <= 0 {
		warnings = append(warnings, "service readiness failed: restored node has no managed Shadowsocks port")
	} else if err := p.configureInstanceFirewall(ctx, instance.ID, ports, instance.Label); err != nil {
		warnings = append(warnings, fmt.Sprintf("Vultr firewall reconciliation failed: %v", err))
	}

	readyPorts := []int{ports.SSPort, ports.VLESSPort, ports.TrojanPort}
	if ports.SSPort > 0 {
		readyErr := p.waitForTCPPorts(ctx, instance.IPv4, readyPorts, 2*time.Second)
		if readyErr != nil && strings.TrimSpace(instance.IPv4) != "" && strings.EqualFold(strings.TrimSpace(instance.Status), "active") {
			if rebootErr := p.rebootInstance(ctx, instance.ID); rebootErr != nil {
				readyErr = fmt.Errorf("%v; in-place reboot failed: %w", readyErr, rebootErr)
			} else {
				select {
				case <-ctx.Done():
					readyErr = ctx.Err()
				case <-time.After(2 * time.Second):
					readyErr = p.waitForTCPPorts(ctx, instance.IPv4, readyPorts, 4*time.Second)
				}
			}
		}
		if readyErr != nil {
			warnings = append(warnings, fmt.Sprintf("service readiness failed: %v", readyErr))
		}
	}

	warning := strings.Join(warnings, "; ")
	persisted, err := p.persistDeploymentWarning(instance.ID, warning)
	if err != nil {
		return nil, fmt.Errorf("persist reconciled Vultr finalization result: %w", err)
	}
	finalized := *instance
	finalized.LastDeployWarning = persisted.LastDeployWarning
	return &finalized, nil
}

var _ cloud.ReconciledCreateFinalizer = (*Provider)(nil)
