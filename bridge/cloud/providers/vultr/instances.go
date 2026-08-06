package vultr

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/deploy"
	"privatedeploy/bridge/cloud/providers/internal/provutil"
)

// instanceCredentials holds generated credentials for a deployment.
type instanceCredentials struct {
	ssPassword        string
	hysteriaPassword  string
	trojanPassword    string
	vlessUUID         string
	realityPrivateKey string
	realityPublicKey  string
	realityShortID    string
	ports             deploy.PortAssignment
}

// ListInstances returns all Vultr instances.
func (p *Provider) ListInstances(ctx context.Context) ([]cloud.Instance, error) {
	records, recordsErr := p.loadNodeRecords()
	if _, err := p.ensureConfig(); err != nil {
		if recordsErr == nil && len(records) > 0 {
			return recordsToInstances(records), nil
		}
		return nil, err
	}

	var payload struct {
		Instances []vultrInstance `json:"instances"`
		Meta      struct {
			Links struct {
				Next string `json:"next"`
			} `json:"links"`
		} `json:"meta"`
	}

	// Fetch every page before reconciling local records. Once one page has
	// succeeded, any later-page error is returned even when an offline snapshot
	// exists: that snapshot must not masquerade as a complete live inventory.
	// In every failure path mutateNodeRecords remains untouched, so credentials
	// for instances on unseen pages cannot be pruned.
	nextPath := "/instances?per_page=100"
	seenPages := make(map[string]struct{})
	pagesFetched := 0
	allInstances := make([]vultrInstance, 0)
	for nextPath != "" {
		if _, duplicate := seenPages[nextPath]; duplicate {
			return nil, fmt.Errorf("%w: repeated Vultr pagination cursor", cloud.ErrAPIRequestFailed)
		}
		seenPages[nextPath] = struct{}{}

		res, err := p.apiRequest(ctx, http.MethodGet, nextPath, nil)
		if err != nil {
			if pagesFetched == 0 && recordsErr == nil && len(records) > 0 {
				return recordsToInstances(records), nil
			}
			return nil, err
		}

		var page struct {
			Instances []vultrInstance `json:"instances"`
			Meta      struct {
				Links struct {
					Next string `json:"next"`
				} `json:"links"`
			} `json:"meta"`
		}
		if err := p.parseResponse(res, &page); err != nil {
			if pagesFetched == 0 && recordsErr == nil && len(records) > 0 {
				return recordsToInstances(records), nil
			}
			return nil, err
		}

		pagesFetched++
		allInstances = append(allInstances, page.Instances...)
		nextPath, err = vultrInstancesPaginationPath(page.Meta.Links.Next)
		if err != nil {
			return nil, err
		}
	}
	payload.Instances = allInstances

	if recordsErr != nil {
		return nil, recordsErr
	}

	// Merge the live instance list into the local records as one atomic
	// read-modify-write: the records mutex is held for the whole cycle
	// (including a fresh re-load) so a concurrent Create/Destroy can never
	// have its write overwritten by our save. The early snapshot above is
	// only used for the API-unreachable fallbacks.
	var instances []cloud.Instance
	mutateErr := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		dirty := false
		liveIDs := make(map[string]struct{}, len(payload.Instances))
		for _, inst := range payload.Instances {
			liveIDs[inst.ID] = struct{}{}
		}
		claimedReplacements := make(map[string]struct{})
		seen := make(map[string]struct{}, len(payload.Instances))
		instances = make([]cloud.Instance, 0, len(payload.Instances))

		for _, inst := range payload.Instances {
			record, ok := records[inst.ID]
			replacedFrom := ""
			replacementDetected := false
			if !ok {
				if oldID, migrated, found := findReplacementNodeRecord(inst, records, liveIDs, claimedReplacements); found {
					record = migrated
					replacedFrom = oldID
					replacementDetected = true
					claimedReplacements[oldID] = struct{}{}
					delete(records, oldID)
					dirty = true
				} else {
					record = nodeRecord{
						InstanceID: inst.ID,
						Label:      inst.Label,
						Region:     inst.Region,
						InstanceRecord: cloud.InstanceRecord{
							Plan:      inst.Plan,
							CreatedAt: inst.CreatedAt,
						},
					}
					dirty = true
				}
			}

			if replacementDetected && clearNodeRecordCredentials(&record) {
				dirty = true
			}

			if replacementDetected || shouldRecoverNodeRecord(record) {
				if recovered, ok := p.recoverNodeRecordForInstance(ctx, inst, record); ok {
					record = recovered
					dirty = true
				}
			}

			if inst.MainIP != "" && record.IPv4 != inst.MainIP {
				record.IPv4 = inst.MainIP
				dirty = true
			}
			if inst.V6MainIP != "" && record.IPv6 != inst.V6MainIP {
				record.IPv6 = inst.V6MainIP
				dirty = true
			}
			if record.CreatedAt == "" && inst.CreatedAt != "" {
				record.CreatedAt = inst.CreatedAt
				dirty = true
			}
			if record.Port == 0 && record.SSPort != 0 {
				record.Port = record.SSPort
				dirty = true
			}
			if inst.Label != "" && record.Label != inst.Label {
				record.Label = inst.Label
				dirty = true
			}
			if inst.Region != "" && record.Region != inst.Region {
				record.Region = inst.Region
				dirty = true
			}
			// Plan is only known at create time from user input; nothing else
			// in this reconciliation loop can derive it. Vultr's own instance
			// payload carries it, so treat it as a live field like
			// Label/Region rather than something only ever set once — this
			// self-heals records whose Plan was lost (e.g. by a past
			// build-fresh-record fallback) instead of leaving them unable to
			// ever repair/redeploy again.
			if inst.Plan != "" && record.Plan != inst.Plan {
				record.Plan = inst.Plan
				dirty = true
			}
			if record.InstanceID == "" {
				record.InstanceID = inst.ID
				dirty = true
			}
			if ensureManagedTLSDefaults(&record.InstanceRecord) {
				dirty = true
			}

			records[inst.ID] = record
			seen[inst.ID] = struct{}{}
			instance := toCloudInstance(inst, record)
			if replacedFrom != "" {
				instance.ReplacedInstanceID = replacedFrom
			}
			instances = append(instances, instance)
		}

		if len(records) > len(seen) {
			for id := range records {
				if _, ok := seen[id]; !ok {
					delete(records, id)
					dirty = true
				}
			}
		}

		return dirty, nil
	})
	if mutateErr != nil && instances == nil {
		// The re-load inside the mutate failed before the merge ran; a save
		// failure (instances already built) stays best-effort as before.
		return nil, mutateErr
	}

	sort.Slice(instances, func(i, j int) bool {
		a := instances[i].CreatedAt
		b := instances[j].CreatedAt
		if !a.IsZero() && !b.IsZero() {
			return a.Before(b)
		}
		return instances[i].ID < instances[j].ID
	})

	return instances, nil
}

// vultrInstancesPaginationPath accepts both forms returned by Vultr over
// time: an opaque cursor token and an absolute/relative next-page URI. For a
// URI, only the configured Vultr API origin is accepted before the bearer
// token is reused.
func vultrInstancesPaginationPath(next string) (string, error) {
	next = strings.TrimSpace(next)
	if next == "" {
		return "", nil
	}

	// Cursor tokens are opaque and may themselves contain base64 punctuation
	// such as '/'. Only unmistakable URI forms should be parsed as links.
	if !strings.HasPrefix(next, "http://") &&
		!strings.HasPrefix(next, "https://") &&
		!strings.HasPrefix(next, "/") &&
		!strings.HasPrefix(next, "?") {
		return "/instances?per_page=100&cursor=" + url.QueryEscape(next), nil
	}

	apiBase, err := url.Parse(vultrAPIBaseURL)
	if err != nil {
		return "", fmt.Errorf("%w: invalid Vultr API base URL", cloud.ErrAPIRequestFailed)
	}
	nextURL, err := url.Parse(next)
	if err != nil {
		return "", fmt.Errorf("%w: invalid Vultr pagination URL", cloud.ErrAPIRequestFailed)
	}
	if strings.HasPrefix(next, "?") {
		nextURL.Path = "/instances"
	}
	nextURL = apiBase.ResolveReference(nextURL)
	if !strings.EqualFold(nextURL.Scheme, apiBase.Scheme) || !strings.EqualFold(nextURL.Host, apiBase.Host) {
		return "", fmt.Errorf("%w: Vultr pagination URL changed origin", cloud.ErrAPIRequestFailed)
	}
	requestPath := nextURL.Path
	basePath := strings.TrimRight(apiBase.Path, "/")
	if basePath != "" && strings.HasPrefix(requestPath, basePath+"/") {
		requestPath = strings.TrimPrefix(requestPath, basePath)
	}
	if requestPath != "/instances" {
		return "", fmt.Errorf("%w: invalid Vultr instances pagination path", cloud.ErrAPIRequestFailed)
	}
	nextURL.Path = requestPath
	nextURL.Scheme = ""
	nextURL.Host = ""
	return nextURL.RequestURI(), nil
}

// CreateInstance creates a new Vultr instance.
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}
	if strings.TrimSpace(opts.Label) == "" || strings.TrimSpace(opts.Region) == "" || strings.TrimSpace(opts.Plan) == "" {
		return nil, fmt.Errorf("label, region and plan are required")
	}

	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}

	extra := provutil.MergeExtra(cfg.Extra, opts.Extra)
	tuning := deploy.ResolveDeploymentTuning(extra)
	// Pick a live Reality handshake target at request time so the same value
	// lands in both the deploy script and the node record (Reality needs the
	// client server_name to match the server's handshake target exactly).
	tuning.VLESSServerName = deploy.SelectVLESSRealityTarget(ctx, tuning.VLESSServerName)

	planRAM, err := p.getPlanRAM(ctx, opts.Plan)
	if err != nil {
		planRAM = 1024
	}

	osIDs, err := p.preferredOSIDs(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to determine vultr os ids: %w", err)
	}
	if len(osIDs) == 0 {
		return nil, fmt.Errorf("failed to determine vultr os ids: no compatible images found")
	}

	creds, userData, err := p.generateDeploymentPayload(planRAM, tuning)
	if err != nil {
		return nil, err
	}

	payload, selectedOSID, err := p.createVultrInstance(ctx, opts, osIDs, userData)
	if err != nil {
		return nil, err
	}

	instanceID := payload.Instance.ID

	record := p.buildNodeRecord(instanceID, opts, selectedOSID, planRAM, creds, tuning)
	if err := p.persistNodeRecord(instanceID, record); err != nil {
		// The remote instance exists but its credentials could not be saved
		// locally, so it would be unusable and keep billing. Best-effort
		// compensation: delete it and let the caller retry cleanly.
		if delErr := p.compensateUnrecordedInstance(instanceID); delErr != nil {
			return nil, fmt.Errorf(
				"failed to persist node record for vultr instance %s: %v; compensating delete also failed: %v — delete the instance manually in the Vultr console",
				instanceID, err, delErr,
			)
		}
		return nil, fmt.Errorf(
			"failed to persist node record for vultr instance %s: %w; the instance was deleted (rolled back) — retry the deploy",
			instanceID, err,
		)
	}

	warnings := make([]string, 0, 3)
	instance, err := p.waitForInstance(ctx, instanceID, 15*time.Minute)
	if err == nil {
		record = p.updateRecordFromInstance(instanceID, instance, record)
		if fwErr := p.configureInstanceFirewall(ctx, instanceID, creds.ports, opts.Label); fwErr != nil {
			warnings = append(warnings, fmt.Sprintf(
				"Vultr firewall not attached: %v. Instance is running but only protected by OS-level rules. Free up firewall-group capacity in the Vultr console and redeploy to recover.",
				fwErr,
			))
		}
		readyErr := p.waitForServiceReady(ctx, instance.MainIP, creds.ports, planRAM, extra)
		if readyErr != nil {
			// Cloud-init can finish just as the first readiness window expires
			// while Docker/systemd is still starting the managed protocols. Give
			// the same deployment one bounded second window before recording a
			// residual warning; users should not need to click redeploy merely
			// because the VPS was slow to start.
			readyErr = p.waitForServiceReady(ctx, instance.MainIP, creds.ports, planRAM, extra)
		}
		if readyErr != nil {
			warnings = append(warnings, fmt.Sprintf("service readiness failed: %v", readyErr))
		}
	} else {
		warnings = append(warnings, fmt.Sprintf("instance readiness failed: %v", err))
		instance = payload.Instance
	}
	record.LastDeployWarning = strings.Join(warnings, "; ")
	if record.LastDeployWarning != "" {
		if persistErr := p.persistNodeRecord(instanceID, record); persistErr != nil {
			return nil, fmt.Errorf("failed to persist deployment warning: %w", persistErr)
		}
	}

	cloudInst := toCloudInstance(instance, record)
	cloudInst.Region = payload.Instance.Region
	cloudInst.Status = payload.Instance.Status
	cloudInst.LastDeployWarning = record.LastDeployWarning
	return &cloudInst, nil
}

// generateDeploymentPayload creates credentials and the user-data deployment script.
func (p *Provider) generateDeploymentPayload(planRAM int, tuning deploy.DeploymentTuning) (instanceCredentials, string, error) {
	creds := instanceCredentials{
		ssPassword:       deploy.GenerateRandomPassword(22),
		hysteriaPassword: deploy.GenerateRandomPassword(22),
		trojanPassword:   deploy.GenerateRandomPassword(22),
		vlessUUID:        deploy.GenerateUUID(),
		ports:            deploy.AllocatePorts(tuning.PortProfile),
	}

	if planRAM <= 600 {
		userData := deploy.GenerateLightweightScript(creds.ports.SSPort, creds.ssPassword)
		return creds, userData, nil
	}

	var err error
	creds.realityPrivateKey, creds.realityPublicKey, err = deploy.GenerateRealityKeyPair()
	if err != nil {
		return creds, "", fmt.Errorf("failed to generate reality key pair: %w", err)
	}
	creds.realityShortID = provutil.GenerateShortID()

	userData := deploy.GenerateMultiProtocolScript(deploy.MultiProtocolParams{
		SSPort:           creds.ports.SSPort,
		SSPassword:       creds.ssPassword,
		HysteriaPort:     creds.ports.HysteriaPort,
		HysteriaPassword: creds.hysteriaPassword,
		HysteriaServer:   tuning.HysteriaServerName,
		HysteriaMasqURL:  tuning.HysteriaMasqueradeURL,
		VLESSPort:        creds.ports.VLESSPort,
		VLESSUUID:        creds.vlessUUID,
		VLESSPrivateKey:  creds.realityPrivateKey,
		VLESSPublicKey:   creds.realityPublicKey,
		VLESSShortID:     creds.realityShortID,
		VLESSServer:      tuning.VLESSServerName,
		TrojanPort:       creds.ports.TrojanPort,
		TrojanPassword:   creds.trojanPassword,
		TrojanServer:     tuning.TrojanServerName,
		VLESSRelayPort:   creds.ports.VLESSRelayPort,
		SingBoxVersion:   tuning.SingBoxVersion,
		SingBoxFallback:  tuning.SingBoxFallbackVersion,
	})
	return creds, userData, nil
}

// createVultrInstance calls the Vultr API with OS ID fallback.
func (p *Provider) createVultrInstance(ctx context.Context, opts *cloud.CreateInstanceOptions, osIDs []int, userData string) (struct {
	Instance vultrInstance `json:"instance"`
}, int, error) {
	requestBody := map[string]any{
		"region":      opts.Region,
		"plan":        opts.Plan,
		"label":       opts.Label,
		"enable_ipv6": true,
		"user_data":   base64.StdEncoding.EncodeToString([]byte(userData)),
	}
	if sshKeyID := strings.TrimSpace(opts.SSHKeyID); sshKeyID != "" {
		requestBody["sshkey_id"] = []string{sshKeyID}
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	var lastErr error
	selectedOSID := 0

	for _, osID := range osIDs {
		requestBody["os_id"] = osID
		res, err := p.apiRequest(ctx, http.MethodPost, "/instances", requestBody)
		if err != nil {
			lastErr = err
			continue
		}
		var attempt struct {
			Instance vultrInstance `json:"instance"`
		}
		if err := p.parseResponse(res, &attempt); err != nil {
			msg := strings.ToLower(err.Error())
			if strings.Contains(msg, "os_id") || strings.Contains(msg, "os id") {
				lastErr = err
				continue
			}
			return payload, 0, err
		}
		payload = attempt
		selectedOSID = osID
		lastErr = nil
		break
	}
	if lastErr != nil {
		return payload, 0, lastErr
	}
	return payload, selectedOSID, nil
}

// buildNodeRecord constructs the initial node record for persistence.
func (p *Provider) buildNodeRecord(instanceID string, opts *cloud.CreateInstanceOptions, osID, planRAM int, creds instanceCredentials, tuning deploy.DeploymentTuning) nodeRecord {
	record := nodeRecord{
		InstanceID: instanceID,
		Label:      opts.Label,
		Region:     opts.Region,
		InstanceRecord: cloud.InstanceRecord{
			Plan:       opts.Plan,
			OSID:       osID,
			Port:       creds.ports.SSPort,
			Password:   creds.ssPassword,
			CreatedAt:  time.Now().UTC().Format(time.RFC3339),
			SSPort:     creds.ports.SSPort,
			SSPassword: creds.ssPassword,
		},
	}
	if planRAM > 600 {
		record.HysteriaPort = creds.ports.HysteriaPort
		record.HysteriaPassword = creds.hysteriaPassword
		record.HysteriaServerName = tuning.HysteriaServerName
		record.HysteriaInsecure = deploy.BoolPtr(tuning.HysteriaInsecure)
		record.VLESSPort = creds.ports.VLESSPort
		record.VLESSUUID = creds.vlessUUID
		record.VLESSPublicKey = creds.realityPublicKey
		record.VLESSShortID = creds.realityShortID
		record.VLESSServerName = tuning.VLESSServerName
		record.TrojanPort = creds.ports.TrojanPort
		record.TrojanPassword = creds.trojanPassword
		record.TrojanServerName = tuning.TrojanServerName
		record.TrojanInsecure = deploy.BoolPtr(tuning.TrojanInsecure)
		record.VLESSRelayPort = creds.ports.VLESSRelayPort
	}
	return record
}

// compensateUnrecordedInstance deletes a just-created instance whose node
// record could not be persisted. It deliberately uses a fresh context so a
// canceled request context cannot strand the orphaned instance.
func (p *Provider) compensateUnrecordedInstance(instanceID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	res, err := p.apiRequest(ctx, http.MethodDelete, "/instances/"+instanceID, nil)
	if err != nil {
		return err
	}
	// 404 means the instance is already gone; the compensation goal (no
	// orphaned, billing instance) is met, so treat it as success rather than
	// a failed rollback.
	if res.StatusCode == http.StatusNotFound {
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
		return nil
	}
	return p.parseResponse(res, nil)
}

// persistNodeRecord saves the node record to disk as an atomic upsert.
func (p *Provider) persistNodeRecord(instanceID string, record nodeRecord) error {
	return p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records[instanceID] = record
		return true, nil
	})
}

// updateRecordFromInstance updates the persisted record with live instance data.
func (p *Provider) updateRecordFromInstance(instanceID string, instance vultrInstance, record nodeRecord) nodeRecord {
	result := record
	_ = p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		rec := records[instanceID]
		if instance.MainIP != "" {
			rec.IPv4 = instance.MainIP
		}
		if instance.V6MainIP != "" {
			rec.IPv6 = instance.V6MainIP
		}
		if instance.Label != "" && rec.Label != instance.Label {
			rec.Label = instance.Label
		}
		if instance.Region != "" && rec.Region != instance.Region {
			rec.Region = instance.Region
		}
		if instance.Plan != "" && rec.Plan != instance.Plan {
			rec.Plan = instance.Plan
		}
		rec.InstanceID = instanceID
		records[instanceID] = rec
		result = rec
		return true, nil
	})
	return result
}

// waitForServiceReady waits for protocol TCP ports to become reachable.
func (p *Provider) waitForServiceReady(ctx context.Context, ip string, ports deploy.PortAssignment, planRAM int, extra map[string]string) error {
	readyPorts := []int{ports.SSPort}
	if planRAM > 600 {
		readyPorts = append(readyPorts, ports.VLESSPort, ports.TrojanPort)
	}
	readyTimeout := provutil.ParseServiceReadyTimeout(extra, defaultServiceReadyTimeout)
	return p.waitForTCPPorts(ctx, ip, readyPorts, readyTimeout)
}

// DestroyInstance destroys a Vultr instance. A 404 from Vultr means the
// instance is already gone on their side (deleted out-of-band, expired
// trial, etc.) — that still satisfies the caller's goal of "this instance
// should no longer exist", so it is treated as success and the stale local
// record is purged rather than left permanently un-deletable.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if strings.TrimSpace(instanceID) == "" {
		return cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return err
	}

	res, err := p.apiRequest(ctx, http.MethodDelete, "/instances/"+instanceID, nil)
	if err != nil {
		return err
	}
	if res.StatusCode == http.StatusNotFound {
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
	} else if err := p.parseResponse(res, nil); err != nil {
		return err
	}

	_ = p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if _, ok := records[instanceID]; !ok {
			return false, nil
		}
		delete(records, instanceID)
		return true, nil
	})

	return nil
}

// GetInstance retrieves a specific Vultr instance.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if instanceID == "" {
		return nil, cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}

	res, err := p.apiRequest(ctx, http.MethodGet, "/instances/"+instanceID, nil)
	if err != nil {
		return nil, err
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return nil, err
	}

	var record nodeRecord
	_ = p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record = records[instanceID]
		if !ensureManagedTLSDefaults(&record.InstanceRecord) {
			return false, nil
		}
		records[instanceID] = record
		return true, nil
	})

	instance := toCloudInstance(payload.Instance, record)
	instance.Region = payload.Instance.Region
	instance.Status = payload.Instance.Status
	return &instance, nil
}

func (p *Provider) waitForInstance(ctx context.Context, instanceID string, timeout time.Duration) (vultrInstance, error) {
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	var lastErr error

	for {
		select {
		case <-waitCtx.Done():
			if lastErr != nil {
				return vultrInstance{}, lastErr
			}
			return vultrInstance{}, errors.New("timeout waiting for instance to become active")
		case <-ticker.C:
			inst, err := p.getInstanceRaw(waitCtx, instanceID)
			if err != nil {
				lastErr = err
				continue
			}
			if inst.Status == "active" && inst.MainIP != "" {
				return inst, nil
			}
		}
	}
}

func (p *Provider) getInstanceRaw(ctx context.Context, instanceID string) (vultrInstance, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/instances/"+instanceID, nil)
	if err != nil {
		return vultrInstance{}, err
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	if err := p.parseResponse(res, &payload); err != nil {
		return vultrInstance{}, err
	}

	return payload.Instance, nil
}

// CleanInvalidNodes removes node records that lack proxy configuration.
// Returns the number of records removed.
func (p *Provider) CleanInvalidNodes(ctx context.Context) (int, error) {
	removed := 0
	err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		for id, record := range records {
			if validateNodeRecord(record) {
				continue
			}
			fmt.Printf("[CleanInvalidNodes] Removing invalid node: %s (label=%s, ssPort=%d)\n",
				id, record.Label, record.SSPort)
			delete(records, id)
			removed++
		}
		if removed == 0 {
			return false, nil
		}
		fmt.Printf("[CleanInvalidNodes] Saving %d valid records (removed %d invalid)\n", len(records), removed)
		return true, nil
	})
	if err != nil {
		return 0, fmt.Errorf("failed to clean node records: %w", err)
	}

	if removed > 0 {
		fmt.Printf("[CleanInvalidNodes] Successfully saved cleaned records to %s\n", p.nodesPath)
	}

	return removed, nil
}
