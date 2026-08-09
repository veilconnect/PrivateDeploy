package vultr

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
)

var (
	repairInitialProbeTimeout = 2 * time.Second
	repairPostSSHProbeTimeout = 35 * time.Second
	repairRebootSettleDelay   = 3 * time.Second
	repairRebootProbeTimeout  = 30 * time.Second
)

// RepairInstance repairs a managed Vultr instance in place. It deliberately
// never creates a replacement instance: a repair action must not silently add
// another billable VPS. The operation reconciles the cloud firewall, reboots
// the existing VM only when its ports are still unavailable, and clears the
// persisted deployment warning after a successful readiness check.
func (p *Provider) RepairInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if !isCanonicalVultrInstanceID(instanceID) {
		return nil, cloud.ErrInstanceNotFound
	}

	_, err := p.ensureConfig()
	if err != nil {
		return nil, err
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
	ports := vultrPortsFromInstance(instance)
	if ports.SSPort <= 0 {
		return nil, p.persistRepairFailure(instanceID, "repair failed: managed node credentials are missing")
	}

	if err := p.configureInstanceFirewall(ctx, instanceID, ports, instance.Label); err != nil {
		return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair failed: Vultr firewall reconciliation failed: %v", err))
	}

	planRAM, err := p.getPlanRAM(ctx, instance.Plan)
	if err != nil {
		planRAM = 1024
	}
	readyPorts := vultrReadyPorts(ports, planRAM)
	// Avoid touching a healthy node. When protocol ports are unavailable, a
	// node created by this version can rerun its original deployment payload via
	// the managed SSH key. This is strictly an in-place repair: this method has
	// no create endpoint and never substitutes another billable VPS.
	if err := p.waitForTCPPorts(ctx, instance.IPv4, readyPorts, repairInitialProbeTimeout); err != nil {
		sshEligible, sshRepairErr := p.rerunManagedDeployment(ctx, instanceID, instance.IPv4)
		if ctx.Err() != nil {
			return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair canceled: %v", ctx.Err()))
		}
		if sshEligible && sshRepairErr == nil {
			if readyErr := p.waitForTCPPorts(ctx, instance.IPv4, readyPorts, repairPostSSHProbeTimeout); readyErr == nil {
				return p.finishRepairSuccess(ctx, instanceID)
			}
			if ctx.Err() != nil {
				return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair canceled: %v", ctx.Err()))
			}
		}

		// Missing credentials or an unavailable SSH service retain one short,
		// bounded same-node network recovery path (firewall was reconciled above,
		// then a reboot and probe); never create or replace an instance.
		fallbackErr := p.boundedSameNodeNetworkRepair(ctx, instanceID, instance.IPv4, readyPorts)
		if fallbackErr == nil {
			return p.finishRepairSuccess(ctx, instanceID)
		}
		if ctx.Err() != nil {
			return nil, p.persistRepairFailure(instanceID, fmt.Sprintf("repair canceled: %v", ctx.Err()))
		}

		warning := "repair incomplete: managed services on the existing Vultr instance are still unavailable after bounded firewall/reboot recovery"
		switch {
		case !sshEligible:
			warning += "; this legacy node predates the managed SSH recovery key, so its deployment script cannot be rerun automatically without an unsafe password handoff"
		case sshRepairErr != nil:
			warning += fmt.Sprintf("; managed SSH deployment rerun failed: %v", sshRepairErr)
		default:
			warning += "; the managed deployment script reran, but its service ports did not become reachable"
		}
		warning += fmt.Sprintf("; bounded same-node recovery failed: %v; no replacement instance was created", fallbackErr)
		return nil, p.persistRepairFailure(instanceID, warning)
	}

	return p.finishRepairSuccess(ctx, instanceID)
}

func (p *Provider) finishRepairSuccess(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if err := p.setDeployWarning(instanceID, ""); err != nil {
		return nil, fmt.Errorf("repair succeeded but failed to clear deployment warning: %w", err)
	}
	instance, err := p.GetInstance(ctx, instanceID)
	if err != nil {
		return nil, err
	}
	instance.LastDeployWarning = ""
	return instance, nil
}

// rerunManagedDeployment reports eligible=false for records created before the
// managed Vultr key was introduced. A fingerprint is persisted at create time
// so a locally replaced/re-generated private key is never tried against a node
// that received different key material.
func (p *Provider) rerunManagedDeployment(ctx context.Context, instanceID, ip string) (eligible bool, err error) {
	records, err := p.loadNodeRecords()
	if err != nil {
		return true, errors.New("managed SSH repair metadata is unavailable")
	}
	record, ok := records[instanceID]
	wantFingerprint := strings.TrimSpace(record.ManagedSSHKeyFingerprint)
	if !ok || wantFingerprint == "" {
		return false, nil
	}

	// Repair must be read-only with respect to account SSH-key resources. The
	// existing VPS already has this public key in authorized_keys; re-listing or
	// re-registering it here could fail under a narrower token or mutate the
	// account without helping the instance being repaired.
	privatePEM, err := cloud.LoadSecret(p.configPath, managedSSHKeyScope)
	if err != nil {
		return true, errors.New("managed SSH recovery key is unavailable")
	}
	privatePEM = strings.TrimSpace(privatePEM)
	if privatePEM == "" {
		return true, errors.New("managed SSH recovery key is unavailable")
	}
	_, currentFingerprint, err := managedPublicKeyFromPEM(privatePEM)
	if err != nil {
		return true, errors.New("managed SSH recovery key is invalid")
	}
	if currentFingerprint != wantFingerprint {
		return true, errors.New("managed SSH recovery key no longer matches this node")
	}
	runner := p.runManagedSSHRepair
	if runner == nil {
		runner = runRemoteDeploymentRepair
	}
	if err := runner(ctx, ip, privatePEM); err != nil {
		if ctx.Err() != nil {
			return true, ctx.Err()
		}
		return true, err
	}
	return true, nil
}

func (p *Provider) boundedSameNodeNetworkRepair(ctx context.Context, instanceID, ip string, readyPorts []int) error {
	if err := p.rebootInstance(ctx, instanceID); err != nil {
		return fmt.Errorf("same-instance reboot failed: %w", err)
	}
	timer := time.NewTimer(repairRebootSettleDelay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
	}
	if err := p.waitForTCPPorts(ctx, ip, readyPorts, repairRebootProbeTimeout); err != nil {
		return fmt.Errorf("service ports remained unavailable after same-instance reboot: %w", err)
	}
	return nil
}

func (p *Provider) RefreshInstanceHealth(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	instance, err := p.GetInstance(ctx, instanceID)
	if err != nil || instance == nil || strings.TrimSpace(instance.LastDeployWarning) == "" {
		return instance, err
	}
	if !isVultrTCPReadinessWarning(instance.LastDeployWarning) {
		return instance, nil
	}
	ports := vultrPortsFromInstance(instance)
	if ports.SSPort <= 0 || strings.TrimSpace(instance.SSPassword) == "" {
		return instance, fmt.Errorf("cannot verify readiness without managed Shadowsocks credentials")
	}
	readyPorts := []int{ports.SSPort, ports.VLESSPort, ports.TrojanPort}
	if err := p.waitForTCPPorts(ctx, instance.IPv4, readyPorts, 2*time.Second); err != nil {
		return instance, err
	}
	if err := p.setDeployWarning(instanceID, ""); err != nil {
		return instance, err
	}
	instance.LastDeployWarning = ""
	return instance, nil
}

func isVultrTCPReadinessWarning(warning string) bool {
	parts := strings.Split(warning, ";")
	found := false
	for _, part := range parts {
		normalized := strings.ToLower(strings.TrimSpace(part))
		if normalized == "" {
			continue
		}
		if !strings.HasPrefix(normalized, "service readiness failed:") &&
			!strings.HasPrefix(normalized, "instance readiness failed:") {
			return false
		}
		found = true
	}
	return found
}

func vultrPortsFromInstance(instance *cloud.Instance) deploy.PortAssignment {
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

func vultrReadyPorts(ports deploy.PortAssignment, planRAM int) []int {
	ready := []int{ports.SSPort}
	if planRAM > 600 {
		ready = append(ready, ports.VLESSPort, ports.TrojanPort)
	}
	return ready
}

func (p *Provider) rebootInstance(ctx context.Context, instanceID string) error {
	res, err := p.apiRequest(ctx, http.MethodPost, "/instances/"+instanceID+"/reboot", nil)
	if err != nil {
		return err
	}
	return p.parseResponse(res, nil)
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
