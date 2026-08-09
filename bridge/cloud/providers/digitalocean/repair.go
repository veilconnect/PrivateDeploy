package digitalocean

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

const (
	digitalOceanRepairQuickProbeTimeout    = 2 * time.Second
	digitalOceanRepairReadyTimeout         = 90 * time.Second
	digitalOceanRepairProtocolProbeTimeout = 45 * time.Second
)

type digitalOceanServiceRepairOps struct {
	probe func(context.Context, string, []int, time.Duration) []int
	rerun func(context.Context, string) error
	wait  func(context.Context, string, []int, time.Duration) (*cloud.Instance, error)
}

// repairDigitalOceanServicePorts performs the destructive-looking part of a
// repair without ever touching droplet lifecycle APIs. A healthy node is left
// alone. An unhealthy node gets exactly one SSH user-data rerun on that same
// address, followed by one short, bounded readiness window.
func repairDigitalOceanServicePorts(
	ctx context.Context,
	instance *cloud.Instance,
	instanceID string,
	ports []int,
	ops digitalOceanServiceRepairOps,
) (*cloud.Instance, error) {
	if instance == nil || strings.TrimSpace(instanceID) == "" {
		return nil, cloud.ErrInstanceNotFound
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	address := strings.TrimSpace(instance.IPv4)
	if address == "" {
		return nil, errors.New("existing droplet has no public IPv4 address for managed SSH repair")
	}
	requiredPorts := provutil.UniquePositivePorts(ports)
	if len(requiredPorts) == 0 {
		return nil, errors.New("managed service ports are missing")
	}
	if ops.probe == nil || ops.rerun == nil || ops.wait == nil {
		return nil, errors.New("DigitalOcean repair operations are incomplete")
	}

	pending := ops.probe(ctx, address, requiredPorts, digitalOceanRepairQuickProbeTimeout)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(pending) == 0 {
		return instance, nil
	}

	if err := ops.rerun(ctx, address); err != nil {
		return nil, fmt.Errorf("managed deployment script rerun failed on the existing droplet: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	repaired, err := ops.wait(ctx, instanceID, requiredPorts, digitalOceanRepairReadyTimeout)
	if err != nil {
		return nil, fmt.Errorf("existing droplet did not become ready after its managed deployment script reran: %w", err)
	}
	if repaired == nil {
		return nil, errors.New("existing droplet readiness check returned no instance")
	}
	return repaired, nil
}

// RepairInstance reconciles and validates an existing droplet in place. It
// never creates a replacement droplet, so clicking Repair cannot silently
// increase the user's bill.
func (p *Provider) RepairInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if _, err := parseDigitalOceanInstanceID(instanceID); err != nil {
		return nil, cloud.ErrInstanceNotFound
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	if _, owned := records[instanceID]; !owned {
		return nil, cloud.ErrInstanceNotFound
	}
	instance, err := p.GetInstance(ctx, instanceID)
	if err != nil {
		return nil, err
	}
	dropletID, err := parseDigitalOceanInstanceID(instanceID)
	if err != nil {
		return nil, cloud.ErrInstanceNotFound
	}
	ports := digitalOceanPortsFromInstance(instance)
	if ports.SSPort <= 0 {
		return nil, p.persistRepairFailure(instanceID, "repair failed: managed node credentials are missing")
	}

	if fwErr := p.configureInstanceFirewall(ctx, instanceID, dropletID, ports); fwErr != nil {
		return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair failed: DigitalOcean firewall reconciliation failed: %v", fwErr))
	}

	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}
	readyPorts := provutil.UniquePositivePorts([]int{ports.SSPort, ports.VLESSPort, ports.TrojanPort})
	repaired, repairErr := repairDigitalOceanServicePorts(
		ctx,
		instance,
		instanceID,
		readyPorts,
		digitalOceanServiceRepairOps{
			probe: provutil.PendingTCPPortsContext,
			rerun: func(rerunCtx context.Context, address string) error {
				return p.rerunManagedUserData(rerunCtx, instanceID, address)
			},
			wait: p.waitForInstanceAndTCPPorts,
		},
	)
	if repairErr != nil {
		return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair failed: %v", repairErr))
	}

	// TCP reachability proves that the services listen, not that their
	// credentials/protocol handshakes work. Keep the existing protocol probes,
	// but disable their old reboot-based self-heal and cap the whole verification
	// pass. The SSH rerun above is now the one repair action for this user click.
	verificationExtra := provutil.MergeExtra(cfg.Extra, map[string]string{
		"protocolRepairAttempts":  "0",
		"serviceReadyTimeoutSec":  "15",
		"protocolProbeTimeoutSec": "15",
	})
	verificationCtx, verificationCancel := context.WithTimeout(ctx, digitalOceanRepairProtocolProbeTimeout)
	verified, verifyErr := p.ensureProtocolReadinessWithRepair(verificationCtx, instanceID, dropletID, ports, verificationExtra)
	verificationCancel()
	if verifyErr != nil {
		return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair failed: protocol verification failed after in-place repair: %v", verifyErr))
	}
	if verified != nil {
		repaired = verified
	}

	if err := p.setDeployWarning(instanceID, ""); err != nil {
		return nil, fmt.Errorf("repair succeeded but failed to clear deployment warning: %w", err)
	}
	repaired.LastDeployWarning = ""
	return repaired, nil
}

func (p *Provider) RefreshInstanceHealth(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	instance, err := p.GetInstance(ctx, instanceID)
	if err != nil || instance == nil || strings.TrimSpace(instance.LastDeployWarning) == "" {
		return instance, err
	}
	if !isDigitalOceanTCPReadinessWarning(instance.LastDeployWarning) {
		return instance, nil
	}
	ports := digitalOceanPortsFromInstance(instance)
	if ports.SSPort <= 0 || ports.VLESSPort <= 0 || ports.TrojanPort <= 0 ||
		strings.TrimSpace(instance.SSPassword) == "" ||
		strings.TrimSpace(instance.VLESSUUID) == "" ||
		strings.TrimSpace(instance.TrojanPassword) == "" {
		return instance, fmt.Errorf("cannot verify readiness without complete managed protocol credentials")
	}
	refreshed, err := p.waitForInstanceAndTCPPorts(ctx, instanceID, []int{ports.SSPort, ports.VLESSPort, ports.TrojanPort}, 2*time.Second)
	if err != nil {
		return instance, err
	}
	if err := p.setDeployWarning(instanceID, ""); err != nil {
		return instance, err
	}
	if refreshed == nil {
		refreshed = instance
	}
	refreshed.LastDeployWarning = ""
	return refreshed, nil
}

func isDigitalOceanTCPReadinessWarning(warning string) bool {
	parts := strings.Split(warning, ";")
	found := false
	for _, part := range parts {
		normalized := strings.ToLower(strings.TrimSpace(part))
		if normalized == "" {
			continue
		}
		if !strings.HasPrefix(normalized, "instance/tcp readiness failed:") {
			return false
		}
		found = true
	}
	return found
}

func digitalOceanPortsFromInstance(instance *cloud.Instance) deploy.PortAssignment {
	if instance == nil {
		return deploy.PortAssignment{}
	}
	return deploy.PortAssignment{
		SSPort:         instance.SSPort,
		HysteriaPort:   instance.HysteriaPort,
		VLESSPort:      instance.VLESSPort,
		TrojanPort:     instance.TrojanPort,
		VLESSRelayPort: instance.VLESSRelayPort,
	}
}

func (p *Provider) persistRepairFailure(instanceID, warning string) error {
	if err := p.setDeployWarning(instanceID, warning); err != nil {
		return fmt.Errorf("%s; failed to persist warning: %v", warning, err)
	}
	return errors.New(warning)
}

func (p *Provider) setDeployWarning(instanceID, warning string) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok {
			return false, cloud.ErrInstanceNotFound
		}
		if record.LastDeployWarning == warning {
			return false, nil
		}
		record.LastDeployWarning = warning
		records[instanceID] = record
		return true, nil
	})
}

var _ cloud.InstanceRepairer = (*Provider)(nil)
var _ cloud.InstanceHealthRefresher = (*Provider)(nil)
