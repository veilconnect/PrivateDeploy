package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"

	"privatedeploy/bridge/cdn"
	"privatedeploy/bridge/cloud"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// CdnState mirrors cdn.State for the JS bridge — kept as a thin alias so
// Vue's TS types stay aligned with the Go-side struct.
type CdnState = cdn.State

// GetCdnStateTyped returns the current CDN configuration snapshot.
func (a *App) GetCdnStateTyped() (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{Status: cdn.StatusDisabled, Deployments: map[string]*cdn.Deployment{}}, nil
	}
	return a.CdnManager.State(), nil
}

// GetCdnState — JSON-wrapped variant for legacy Vue callers.
func (a *App) GetCdnState() FlagResult {
	state, err := a.GetCdnStateTyped()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	data, err := json.Marshal(state)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: string(data)}
}

// VerifyCdnTokenTyped runs token verification + persists result on success.
func (a *App) VerifyCdnTokenTyped(token string) (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{}, errors.New("cdn manager not initialized")
	}
	state, err := a.CdnManager.VerifyAndPersist(a.bgCtx(), token)
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// VerifyCdnToken — Vue-friendly variant.
func (a *App) VerifyCdnToken(token string) FlagResult {
	state, err := a.VerifyCdnTokenTyped(token)
	if err != nil {
		log.Printf("[CdnBridge] verify failed: %v", err)
		// Even on failure return state so the UI can show lastError.
		data, _ := json.Marshal(state)
		return FlagResult{Flag: false, Data: string(data)}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// ClearCdnTyped wipes all CDN state from disk. Best-effort cleanup of
// remote Workers + custom-domain bindings runs first while credentials
// are still available; transient failures don't block the local wipe.
func (a *App) ClearCdnTyped() (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{Status: cdn.StatusDisabled, Deployments: map[string]*cdn.Deployment{}}, nil
	}
	state, err := a.CdnManager.Clear(a.Ctx)
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// ClearCdn — Vue-friendly variant.
func (a *App) ClearCdn() FlagResult {
	state, err := a.ClearCdnTyped()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// DeployCdnWorkerForNodeTyped looks up the active provider's instance for
// nodeID, then deploys a Worker fronting its plain VLESS relay port.
func (a *App) DeployCdnWorkerForNodeTyped(nodeID string) (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{}, errors.New("cdn manager not initialized")
	}
	host, port, label, err := a.lookupCdnBackendForNode(nodeID)
	if err != nil {
		return a.CdnManager.State(), err
	}
	state, err := a.CdnManager.DeployWorker(a.bgCtx(), nodeID, label, host, port)
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// DeployCdnWorkerForNode — Vue-friendly variant.
func (a *App) DeployCdnWorkerForNode(nodeID string) FlagResult {
	state, err := a.DeployCdnWorkerForNodeTyped(nodeID)
	if err != nil {
		log.Printf("[CdnBridge] deploy %s failed: %v", nodeID, err)
		data, _ := json.Marshal(state)
		return FlagResult{Flag: false, Data: string(data)}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// DeleteCdnWorkerForNodeTyped removes the Worker for nodeID from CF and
// clears the local deployment record.
func (a *App) DeleteCdnWorkerForNodeTyped(nodeID string) (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{}, errors.New("cdn manager not initialized")
	}
	state, err := a.CdnManager.DeleteWorker(a.bgCtx(), nodeID)
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// DeleteCdnWorkerForNode — Vue-friendly variant.
func (a *App) DeleteCdnWorkerForNode(nodeID string) FlagResult {
	state, err := a.DeleteCdnWorkerForNodeTyped(nodeID)
	if err != nil {
		data, _ := json.Marshal(state)
		return FlagResult{Flag: false, Data: string(data)}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// ListCdnZonesTyped returns the active CF zones the verified token can see.
// Used by the Settings UI to populate the M1 custom-domain zone picker.
func (a *App) ListCdnZonesTyped() ([]cdn.Zone, error) {
	if a.CdnManager == nil {
		return nil, errors.New("cdn manager not initialized")
	}
	return a.CdnManager.ListZones(a.bgCtx())
}

// ListCdnZones — Vue-friendly variant. Returns Flag=true with JSON-encoded
// []Zone in Data on success; Flag=false with the error message in Data on
// failure (e.g. token not verified, network error).
func (a *App) ListCdnZones() FlagResult {
	zones, err := a.ListCdnZonesTyped()
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	data, err := json.Marshal(zones)
	if err != nil {
		return FlagResult{Flag: false, Data: err.Error()}
	}
	return FlagResult{Flag: true, Data: string(data)}
}

// SetCdnCustomDomainTyped persists the M1 binding for future deploys.
// Returns the new full CdnState so the UI can refresh in one round-trip.
func (a *App) SetCdnCustomDomainTyped(zoneID, subdomain string) (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{}, errors.New("cdn manager not initialized")
	}
	state, err := a.CdnManager.SetCustomDomain(a.bgCtx(), zoneID, subdomain)
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// SetCdnCustomDomain — Vue-friendly variant. Failure path still attaches
// state so the UI can render lastError.
func (a *App) SetCdnCustomDomain(zoneID, subdomain string) FlagResult {
	state, err := a.SetCdnCustomDomainTyped(zoneID, subdomain)
	if err != nil {
		log.Printf("[CdnBridge] set custom domain failed: %v", err)
		data, _ := json.Marshal(state)
		return FlagResult{Flag: false, Data: string(data)}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// ClearCdnCustomDomainTyped wipes the M1 binding config. Existing
// deployments retain their bindings on disk so DeleteWorker can clean them
// up; only future deploys revert to workers.dev only.
func (a *App) ClearCdnCustomDomainTyped() (CdnState, error) {
	if a.CdnManager == nil {
		return CdnState{}, errors.New("cdn manager not initialized")
	}
	state, err := a.CdnManager.ClearCustomDomain()
	a.emitCdnEvent("cdn:state", state)
	return state, err
}

// ClearCdnCustomDomain — Vue-friendly variant.
func (a *App) ClearCdnCustomDomain() FlagResult {
	state, err := a.ClearCdnCustomDomainTyped()
	if err != nil {
		data, _ := json.Marshal(state)
		return FlagResult{Flag: false, Data: string(data)}
	}
	data, _ := json.Marshal(state)
	return FlagResult{Flag: true, Data: string(data)}
}

// lookupCdnBackendForNode finds the cloud instance with the given ID across
// all enabled providers, returning (host, vlessRelayPort, label).
func (a *App) lookupCdnBackendForNode(nodeID string) (string, int, string, error) {
	inst, err := a.findInstanceByID(nodeID)
	if err != nil {
		return "", 0, "", err
	}
	if inst.VLESSRelayPort <= 0 {
		return "", 0, "", fmt.Errorf("node %s has no VLESS relay port — re-deploy it to enable CDN front", nodeID)
	}
	host := inst.IPv4
	if host == "" {
		host = inst.IPv6
	}
	if host == "" {
		return "", 0, "", fmt.Errorf("node %s has no public IP", nodeID)
	}
	label := inst.Label
	if label == "" {
		label = inst.ID
	}
	return host, inst.VLESSRelayPort, label, nil
}

// findInstanceByID iterates providers and returns the first match.
func (a *App) findInstanceByID(nodeID string) (*cloud.Instance, error) {
	if a.CloudManager == nil {
		return nil, errors.New("cloud manager not initialized")
	}
	ctx := a.bgCtx()
	for _, name := range a.CloudManager.ListProviders() {
		p, err := a.CloudManager.GetProvider(name)
		if err != nil {
			continue
		}
		if inst, err := p.GetInstance(ctx, nodeID); err == nil && inst != nil {
			return inst, nil
		}
	}
	return nil, fmt.Errorf("instance %s not found", nodeID)
}

func (a *App) bgCtx() context.Context {
	if a.Ctx != nil {
		return a.Ctx
	}
	return context.Background()
}

// emitCdnEvent fires a Vue-side event with the new state attached.
func (a *App) emitCdnEvent(event string, state CdnState) {
	if a == nil || a.Ctx == nil {
		return
	}
	runtime.EventsEmit(a.Ctx, event, state)
}
