package vultr

import (
	"context"
	"encoding/base64"
	"encoding/json"
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

// isCanonicalVultrInstanceID validates the hyphenated UUID form returned by
// Vultr's v2 instance API. Hex case is immaterial; exact local-record matching
// still prevents aliases, while the fixed shape rejects path/query syntax and
// cross-provider IDs.
func isCanonicalVultrInstanceID(instanceID string) bool {
	if len(instanceID) != 36 || instanceID != strings.TrimSpace(instanceID) {
		return false
	}
	allZero := true
	for index, char := range instanceID {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
		if char != '0' {
			allZero = false
		}
	}
	return !allZero
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
	recordsSnapshot := records

	// Reconcile remote disappearance before pruning records. A record carrying
	// a firewall ownership token is also the only durable cleanup credential;
	// deleting it before the provider firewall is gone would leak quota
	// permanently. Cleanup is deliberately outside mutateNodeRecords to avoid
	// holding nodesMu across network I/O (configure takes the locks in the
	// opposite order).
	liveSnapshotIDs := make(map[string]struct{}, len(payload.Instances))
	for _, inst := range payload.Instances {
		liveSnapshotIDs[inst.ID] = struct{}{}
	}
	missingCleanupSucceeded := make(map[string]struct{})
	missingCleanupFailed := make(map[string]struct{})
	missingCleanupDeferred := make(map[string]struct{})
	for id, record := range recordsSnapshot {
		if _, live := liveSnapshotIDs[id]; live {
			continue
		}
		if p.isInstanceCreateActive(id) {
			missingCleanupDeferred[id] = struct{}{}
			continue
		}
		// The collection endpoint can be briefly incomplete. Require an
		// authoritative per-instance 404 before touching the firewall; a live,
		// failed, or ambiguous lookup is preserved for a later refresh.
		missing, confirmErr := p.instanceDefinitelyMissing(ctx, id)
		if confirmErr != nil || !missing {
			missingCleanupDeferred[id] = struct{}{}
			continue
		}
		if strings.TrimSpace(record.FirewallOwnershipToken) == "" {
			// Legacy records have no verifiable, instance-owned firewall group.
			// There is nothing safe for automatic cleanup to delete.
			missingCleanupSucceeded[id] = struct{}{}
			continue
		}
		if err := p.cleanupInstanceFirewallGroups(ctx, id, record.FirewallOwnershipToken); err != nil {
			missingCleanupFailed[id] = struct{}{}
			fmt.Printf("[VultrProvider] preserving hidden record %s for firewall cleanup retry: %v\n", id, err)
			continue
		}
		missingCleanupSucceeded[id] = struct{}{}
	}

	// Merge the live instance list into the local records as one atomic
	// read-modify-write: the records mutex is held for the whole cycle
	// (including a fresh re-load) so a concurrent Create/Destroy can never
	// have its write overwritten by our save. The early snapshot above is
	// only used for the API-unreachable fallbacks.
	var instances []cloud.Instance
	mutateErr := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		dirty := false
		liveIDs := liveSnapshotIDs
		claimedReplacements := make(map[string]struct{})
		// Records absent from the pre-request snapshot were created while the
		// paginated API read was in flight. They must neither be pruned nor used
		// as a replacement candidate based on a coincidental label/IP match.
		for id := range records {
			if _, existedBeforeRequest := recordsSnapshot[id]; !existedBeforeRequest {
				claimedReplacements[id] = struct{}{}
			}
		}
		for id := range missingCleanupFailed {
			claimedReplacements[id] = struct{}{}
		}
		for id := range missingCleanupDeferred {
			claimedReplacements[id] = struct{}{}
		}
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
			if record.FirewallCleanupPending {
				// The instance is present again (for example eventual consistency
				// briefly omitted it), so it is not a cleanup tombstone.
				record.FirewallCleanupPending = false
				dirty = true
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

		for id, current := range records {
			if _, ok := seen[id]; ok {
				continue
			}
			snapshot, existedBeforeRequest := recordsSnapshot[id]
			if !existedBeforeRequest {
				continue
			}
			if _, cleanupFailed := missingCleanupFailed[id]; cleanupFailed {
				if current.FirewallGroupID == snapshot.FirewallGroupID &&
					current.FirewallOwnershipToken == snapshot.FirewallOwnershipToken &&
					!current.FirewallCleanupPending {
					current.FirewallCleanupPending = true
					records[id] = current
					dirty = true
				}
				continue
			}
			if _, cleanupDeferred := missingCleanupDeferred[id]; cleanupDeferred {
				continue
			}
			if _, cleanupSucceeded := missingCleanupSucceeded[id]; !cleanupSucceeded {
				continue
			}
			// A concurrent repair may have assigned a new group after the early
			// snapshot was loaded. Preserve that fresh ownership instead of
			// deleting its only cleanup token based on stale evidence.
			if current.FirewallGroupID != snapshot.FirewallGroupID ||
				current.FirewallOwnershipToken != snapshot.FirewallOwnershipToken {
				continue
			}
			delete(records, id)
			dirty = true
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

	// Vultr cannot attach a key after a server has been created. Provision the
	// account-level recovery key before crossing the billable POST boundary so
	// every newly managed node can be repaired in place later. Failure is fatal
	// here (and safe to retry) because no instance has been requested yet.
	managedSSHKeyID, _, managedSSHKeyFingerprint, err := p.ensureManagedSSHKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("prepare Vultr managed SSH recovery key before create: %w", err)
	}

	creds, userData, err := p.generateDeploymentPayload(planRAM, tuning)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(opts.OperationJournalPath) != "" {
		prepared := vultrCreateOperationData{
			Record:  p.buildNodeRecord("", opts, osIDs[0], planRAM, creds, tuning, managedSSHKeyFingerprint),
			PlanRAM: planRAM,
		}
		if err := cloud.StoreCreateOperationProviderData(opts.OperationJournalPath, cloud.CreateOperationPrepared, prepared); err != nil {
			return nil, fmt.Errorf("journal Vultr credentials before create: %w", err)
		}
		// Submitted is persisted immediately before entering the only code path
		// allowed to POST. After this point every retry must query the exact tag.
		if err := cloud.MarkCreateOperationSubmitted(opts.OperationJournalPath); err != nil {
			return nil, fmt.Errorf("journal Vultr create submission: %w", err)
		}
	}

	payload, selectedOSID, err := p.createVultrInstance(ctx, opts, osIDs, userData, managedSSHKeyID)
	if err != nil {
		return nil, err
	}

	instanceID := payload.Instance.ID
	p.beginInstanceCreate(instanceID)
	defer p.endInstanceCreate(instanceID)

	record := p.buildNodeRecord(instanceID, opts, selectedOSID, planRAM, creds, tuning, managedSSHKeyFingerprint)
	if strings.TrimSpace(opts.OperationJournalPath) != "" {
		if err := cloud.StoreCreateOperationProviderData(opts.OperationJournalPath, cloud.CreateOperationSubmitted, vultrCreateOperationData{
			Record:  record,
			PlanRAM: planRAM,
		}); err != nil {
			return nil, fmt.Errorf("%w: Vultr instance %s exists but its operation journal could not be updated: %v", cloud.ErrCreateOutcomePending, instanceID, err)
		}
		if err := cloud.MarkCreateOperationRemote(opts.OperationJournalPath, instanceID); err != nil {
			return nil, fmt.Errorf("%w: Vultr instance %s exists but its remote id could not be journaled: %v", cloud.ErrCreateOutcomePending, instanceID, err)
		}
	}
	if err := p.persistNodeRecord(instanceID, record); err != nil {
		// The remote instance exists but its credentials could not be saved
		// locally, so it would be unusable and keep billing. Best-effort
		// compensation: delete it and let the caller retry cleanly.
		if delErr := p.compensateUnrecordedInstance(instanceID); delErr != nil {
			return nil, fmt.Errorf(
				"%w: failed to persist node record for vultr instance %s: %v; compensating delete also failed: %v — delete the instance manually in the Vultr console",
				cloud.ErrCreateOutcomePending,
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
		var fwErr error
		if err := p.configureInstanceFirewall(ctx, instanceID, creds.ports, opts.Label); err != nil {
			fwErr = err
			warnings = append(warnings, fmt.Sprintf(
				"Vultr firewall not attached: %v. Instance is running but only protected by OS-level rules. Free up firewall-group capacity in the Vultr console and redeploy to recover.",
				err,
			))
		}
		if fwErr == nil {
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
			// Without the provider firewall, external port probes are not
			// meaningful and can consume two full readiness windows. The node is
			// already active; persist the actionable firewall warning immediately.
			warnings = append(warnings, "service readiness check skipped because Vultr firewall setup failed")
		}
	} else {
		warnings = append(warnings, fmt.Sprintf("instance readiness failed: %v", err))
		instance = payload.Instance
	}
	record.LastDeployWarning = strings.Join(warnings, "; ")
	if record.LastDeployWarning != "" {
		persistedRecord, persistErr := p.persistDeploymentWarning(instanceID, record.LastDeployWarning)
		if persistErr != nil {
			return nil, fmt.Errorf("failed to persist deployment warning: %w", persistErr)
		}
		// Keep the response record in sync while preserving fields (notably
		// firewall ownership) written by lifecycle steps after the local record
		// variable was loaded.
		record = persistedRecord
	}

	cloudInst := toCloudInstance(instance, record)
	cloudInst.Region = payload.Instance.Region
	cloudInst.Status = payload.Instance.Status
	cloudInst.LastDeployWarning = record.LastDeployWarning
	return &cloudInst, nil
}

func (p *Provider) persistDeploymentWarning(instanceID, warning string) (nodeRecord, error) {
	var persisted nodeRecord
	err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		record, ok := records[instanceID]
		if !ok {
			return false, fmt.Errorf("node record %s disappeared while saving deployment warning", instanceID)
		}
		record.LastDeployWarning = warning
		records[instanceID] = record
		persisted = record
		return true, nil
	})
	return persisted, err
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
func (p *Provider) createVultrInstance(ctx context.Context, opts *cloud.CreateInstanceOptions, osIDs []int, userData string, managedSSHKeyIDs ...string) (struct {
	Instance vultrInstance `json:"instance"`
}, int, error) {
	requestBody := map[string]any{
		"region":      opts.Region,
		"plan":        opts.Plan,
		"label":       opts.Label,
		"enable_ipv6": true,
		"user_data":   base64.StdEncoding.EncodeToString([]byte(userData)),
	}
	if strings.TrimSpace(opts.OperationID) != "" {
		requestBody["tags"] = []string{cloud.CreateOperationTag("vultr", opts.OperationID)}
	}
	sshKeyIDs := make([]string, 0, len(managedSSHKeyIDs)+1)
	seenSSHKeyIDs := make(map[string]struct{}, len(managedSSHKeyIDs)+1)
	appendSSHKeyID := func(candidate string) {
		sshKeyID := strings.TrimSpace(candidate)
		if sshKeyID == "" {
			return
		}
		if _, exists := seenSSHKeyIDs[sshKeyID]; exists {
			return
		}
		seenSSHKeyIDs[sshKeyID] = struct{}{}
		sshKeyIDs = append(sshKeyIDs, sshKeyID)
	}
	for _, candidate := range managedSSHKeyIDs {
		appendSSHKeyID(candidate)
	}
	appendSSHKeyID(opts.SSHKeyID)
	if len(sshKeyIDs) > 0 {
		requestBody["sshkey_id"] = sshKeyIDs
	}

	var payload struct {
		Instance vultrInstance `json:"instance"`
	}
	var lastErr error
	for index, osID := range osIDs {
		requestBody["os_id"] = osID
		res, err := p.apiRequest(ctx, http.MethodPost, "/instances", requestBody)
		if err != nil {
			// A transport error does not prove the create was rejected: Vultr may
			// have accepted it before the connection broke. Posting again with a
			// fallback OS could create a second billable VM.
			return payload, 0, fmt.Errorf("%w: Vultr transport failure; request was not retried: %v", cloud.ErrCreateOutcomePending, err)
		}
		body, readErr := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if readErr != nil {
			return payload, 0, fmt.Errorf("%w: Vultr response could not be read; request was not retried: %v", cloud.ErrCreateOutcomePending, readErr)
		}
		if res.StatusCode >= 400 {
			reason := decodeVultrError(body)
			attemptErr := fmt.Errorf("vultr api error (%d %s): %s", res.StatusCode, http.StatusText(res.StatusCode), reason)
			if res.StatusCode >= http.StatusInternalServerError {
				return payload, 0, fmt.Errorf("%w: %v; request was not retried", cloud.ErrCreateOutcomePending, attemptErr)
			}
			if index < len(osIDs)-1 && isExplicitVultrOSIDRejection(res.StatusCode, reason) {
				lastErr = attemptErr
				continue
			}
			return payload, 0, attemptErr
		}
		var attempt struct {
			Instance vultrInstance `json:"instance"`
		}
		if err := json.Unmarshal(body, &attempt); err != nil {
			return payload, 0, fmt.Errorf("%w: Vultr success response was invalid; request was not retried: %v", cloud.ErrCreateOutcomePending, err)
		}
		if strings.TrimSpace(attempt.Instance.ID) == "" {
			return payload, 0, fmt.Errorf("%w: Vultr success response had no instance id; request was not retried", cloud.ErrCreateOutcomePending)
		}
		payload = attempt
		return payload, osID, nil
	}
	if lastErr != nil {
		return payload, 0, lastErr
	}
	return payload, 0, fmt.Errorf("failed to create Vultr instance: no OS candidate was attempted")
}

func isExplicitVultrOSIDRejection(status int, reason string) bool {
	if status < http.StatusBadRequest || status >= http.StatusInternalServerError ||
		status == http.StatusUnauthorized || status == http.StatusForbidden ||
		status == http.StatusConflict || status == http.StatusTooManyRequests {
		return false
	}
	lower := strings.ToLower(reason)
	mentionsOSID := strings.Contains(lower, "os_id") || strings.Contains(lower, "os id")
	explicitlyRejected := strings.Contains(lower, "invalid") ||
		strings.Contains(lower, "unsupported") ||
		strings.Contains(lower, "not available") ||
		strings.Contains(lower, "does not exist") ||
		strings.Contains(lower, "must be")
	return mentionsOSID && explicitlyRejected
}

// buildNodeRecord constructs the initial node record for persistence.
func (p *Provider) buildNodeRecord(instanceID string, opts *cloud.CreateInstanceOptions, osID, planRAM int, creds instanceCredentials, tuning deploy.DeploymentTuning, managedSSHKeyFingerprints ...string) nodeRecord {
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
	if len(managedSSHKeyFingerprints) > 0 {
		record.ManagedSSHKeyFingerprint = strings.TrimSpace(managedSSHKeyFingerprints[0])
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
	if !isCanonicalVultrInstanceID(instanceID) {
		return cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return err
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return fmt.Errorf("failed to load firewall ownership before destroying %s: %w", instanceID, err)
	}
	record, owned := records[instanceID]
	if !owned {
		return cloud.ErrInstanceNotFound
	}
	ownershipToken := record.FirewallOwnershipToken

	// Require an authoritative per-instance GET after local ownership proof.
	// Collection-list absence is never enough to authorize remote or local
	// deletion because provider listings can be transiently incomplete.
	missing, err := p.instanceDefinitelyMissing(ctx, instanceID)
	if err != nil {
		return err
	}
	if !missing {
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
	}

	// The instance no longer exists, so reclaim every firewall group whose
	// deterministic description proves that it belongs to this instance. Keep
	// the local record when cleanup fails: a second Destroy call will treat the
	// instance 404 as success and retry the group deletion instead of silently
	// leaking quota. Legacy shared groups are never removed by this path.
	cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cleanupCancel()
	if err := p.cleanupInstanceFirewallGroups(cleanupCtx, instanceID, ownershipToken); err != nil {
		if markErr := p.markFirewallCleanupPending(instanceID); markErr != nil {
			return fmt.Errorf("instance %s was deleted, but its managed Vultr firewall cleanup failed: %v; additionally failed to preserve the hidden cleanup record: %w", instanceID, err, markErr)
		}
		return fmt.Errorf("instance %s was deleted, but its managed Vultr firewall cleanup failed: %w", instanceID, err)
	}

	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		if _, ok := records[instanceID]; !ok {
			return false, nil
		}
		delete(records, instanceID)
		return true, nil
	}); err != nil {
		return fmt.Errorf("instance %s and its managed firewall were deleted, but the local node record could not be removed: %w", instanceID, err)
	}

	return nil
}

// GetInstance retrieves a specific Vultr instance.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	if !isCanonicalVultrInstanceID(instanceID) {
		return nil, cloud.ErrInstanceNotFound
	}

	if _, err := p.ensureConfig(); err != nil {
		return nil, err
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	if _, owned := records[instanceID]; !owned {
		return nil, cloud.ErrInstanceNotFound
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

func (p *Provider) instanceDefinitelyMissing(ctx context.Context, instanceID string) (bool, error) {
	res, err := p.apiRequest(ctx, http.MethodGet, "/instances/"+instanceID, nil)
	if err != nil {
		return false, err
	}
	if res.StatusCode == http.StatusNotFound {
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
		return true, nil
	}
	if res.StatusCode >= 400 {
		return false, p.parseResponse(res, nil)
	}
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	return false, nil
}

// CleanInvalidNodes removes node records that lack proxy configuration.
// Returns the number of records removed.
func (p *Provider) CleanInvalidNodes(ctx context.Context) (int, error) {
	snapshot, err := p.loadNodeRecords()
	if err != nil {
		return 0, fmt.Errorf("failed to clean node records: %w", err)
	}

	eligible := make(map[string]nodeRecord)
	cleanupFailed := make(map[string]nodeRecord)
	var cleanupErrors []error
	for id, record := range snapshot {
		if validateNodeRecord(record) {
			continue
		}
		// Never turn a still-billing VPS into an invisible local ghost merely
		// because its proxy credentials are incomplete. An authoritative 404 is
		// required before any invalid record can be removed.
		missing, confirmErr := p.instanceDefinitelyMissing(ctx, id)
		if confirmErr != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf("confirm invalid node %s before cleanup: %w", id, confirmErr))
			continue
		}
		if !missing {
			continue
		}
		ownershipToken := strings.TrimSpace(record.FirewallOwnershipToken)
		if ownershipToken == "" {
			if record.FirewallCleanupPending {
				// This tombstone says a prior cleanup did not finish, but it lacks
				// proof that would make deletion safe. Preserve it for operator
				// inspection instead of losing the only evidence of the leak.
				cleanupErrors = append(cleanupErrors, fmt.Errorf("invalid node %s has unresolved firewall cleanup without an ownership token", id))
				continue
			}
			eligible[id] = record
			continue
		}

		if cleanupErr := p.cleanupInstanceFirewallGroups(ctx, id, ownershipToken); cleanupErr != nil {
			cleanupFailed[id] = record
			cleanupErrors = append(cleanupErrors, fmt.Errorf("clean firewall for invalid node %s: %w", id, cleanupErr))
			continue
		}
		eligible[id] = record
	}

	removed := 0
	err = p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		dirty := false
		for id, snapshotRecord := range cleanupFailed {
			current, ok := records[id]
			if !ok || validateNodeRecord(current) || current.FirewallOwnershipToken != snapshotRecord.FirewallOwnershipToken || current.FirewallGroupID != snapshotRecord.FirewallGroupID {
				continue
			}
			if !current.FirewallCleanupPending {
				current.FirewallCleanupPending = true
				records[id] = current
				dirty = true
			}
		}
		for id, snapshotRecord := range eligible {
			current, ok := records[id]
			if !ok || validateNodeRecord(current) || current.FirewallOwnershipToken != snapshotRecord.FirewallOwnershipToken || current.FirewallGroupID != snapshotRecord.FirewallGroupID {
				continue
			}
			fmt.Printf("[CleanInvalidNodes] Removing invalid node: %s (label=%s, ssPort=%d)\n", id, current.Label, current.SSPort)
			delete(records, id)
			removed++
			dirty = true
		}
		return dirty, nil
	})
	if err != nil {
		return 0, fmt.Errorf("failed to clean node records: %w", err)
	}

	if removed > 0 {
		fmt.Printf("[CleanInvalidNodes] Successfully saved cleaned records to %s\n", p.nodesPath)
	}
	if len(cleanupErrors) > 0 {
		return removed, errors.Join(cleanupErrors...)
	}
	return removed, nil
}
