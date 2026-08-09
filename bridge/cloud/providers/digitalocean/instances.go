package digitalocean

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
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
	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}
	recordsSnapshot, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}

	type droplet struct {
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
	}
	type dropletsPage struct {
		Droplets []droplet `json:"droplets"`
		Links    struct {
			Pages struct {
				Next string `json:"next"`
			} `json:"pages"`
		} `json:"links"`
	}

	// Fetch every page before touching local records. A partial live inventory
	// must never reach the reconciliation/prune step: otherwise records for
	// droplets on a later page would be mistaken for deleted instances.
	result := make([]droplet, 0)
	nextPage := baseURL + "/droplets?per_page=200"
	seenPages := make(map[string]struct{})
	for nextPage != "" {
		if _, duplicate := seenPages[nextPage]; duplicate {
			return nil, fmt.Errorf("%w: repeated DigitalOcean pagination URL", cloud.ErrAPIRequestFailed)
		}
		seenPages[nextPage] = struct{}{}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, nextPage, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
		req.Header.Set("Content-Type", "application/json")

		resp, err := p.client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
		}

		var page dropletsPage
		decodeErr := func() error {
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return fmt.Errorf("%w: status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
			}
			return json.NewDecoder(resp.Body).Decode(&page)
		}()
		if decodeErr != nil {
			return nil, decodeErr
		}

		result = append(result, page.Droplets...)
		nextPage, err = digitalOceanPaginationURL(page.Links.Pages.Next)
		if err != nil {
			return nil, err
		}
	}

	liveSnapshotIDs := make(map[string]struct{}, len(result))
	for _, droplet := range result {
		liveSnapshotIDs[fmt.Sprintf("cloud-do-%d", droplet.ID)] = struct{}{}
	}
	missingCleanupSucceeded := make(map[string]struct{})
	missingCleanupFailed := make(map[string]struct{})
	missingCleanupDeferred := make(map[string]struct{})
	for instanceID, record := range recordsSnapshot {
		if _, live := liveSnapshotIDs[instanceID]; live {
			continue
		}
		if p.isInstanceCreateActive(instanceID) {
			missingCleanupDeferred[instanceID] = struct{}{}
			continue
		}
		// A list response can be briefly incomplete. Never remove a firewall
		// based on absence from the collection endpoint alone; require the
		// authoritative per-droplet endpoint to confirm 404.
		missing, confirmErr := p.dropletDefinitelyMissing(ctx, instanceID)
		if confirmErr != nil || !missing {
			missingCleanupDeferred[instanceID] = struct{}{}
			continue
		}
		if strings.TrimSpace(record.FirewallOwnershipToken) == "" {
			missingCleanupSucceeded[instanceID] = struct{}{}
			continue
		}
		if err := p.cleanupInstanceFirewalls(ctx, instanceID, record.FirewallOwnershipToken); err != nil {
			missingCleanupFailed[instanceID] = struct{}{}
			fmt.Fprintf(os.Stderr, "[DigitalOceanProvider] preserving hidden record %s for firewall cleanup retry: %v\n", instanceID, err)
			continue
		}
		missingCleanupSucceeded[instanceID] = struct{}{}
	}

	// Merge the live droplet list into the local records as one atomic
	// read-modify-write: the records mutex is held for the whole cycle so a
	// concurrent Create/Destroy/Get can never have its write overwritten by
	// our save (load→modify→save as separate locked steps allowed lost
	// updates).
	var instances []cloud.Instance
	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		dirty := false
		seen := make(map[string]struct{}, len(result))

		instances = make([]cloud.Instance, 0, len(result))
		for _, d := range result {
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
				record = nodeRecord{}
			}
			if record.FirewallCleanupPending {
				record.FirewallCleanupPending = false
				dirty = true
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
			// user-data, so this is the only recovery path. Best-effort. Recovery
			// runs while holding the records mutex — acceptable, because dropping
			// the lock here would reopen the lost-update window this closure
			// exists to close, and the recovery path never touches the records
			// APIs itself.
			if !cloud.HasMinimumProxyConfig(record.InstanceRecord) && instance.IPv4 != "" {
				if recovered, rok := p.recoverNodeRecordForInstance(ctx, instance.IPv4, record); rok {
					record = recovered
					dirty = true
				}
			}

			if ensureManagedTLSDefaults(&record.InstanceRecord) {
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
			instance.LastDeployWarning = record.LastDeployWarning

			records[instanceID] = record
			seen[instanceID] = struct{}{}

			instances = append(instances, instance)
		}

		for id, current := range records {
			if _, live := seen[id]; live {
				continue
			}
			snapshot, existedBeforeRequest := recordsSnapshot[id]
			if !existedBeforeRequest {
				// Created while the paginated API request was in flight.
				continue
			}
			if _, deferred := missingCleanupDeferred[id]; deferred {
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
			if _, cleaned := missingCleanupSucceeded[id]; !cleaned {
				continue
			}
			if current.FirewallGroupID != snapshot.FirewallGroupID ||
				current.FirewallOwnershipToken != snapshot.FirewallOwnershipToken {
				continue
			}
			delete(records, id)
			dirty = true
		}

		return dirty, nil
	}); err != nil {
		return nil, err
	}

	return instances, nil
}

// digitalOceanPaginationURL resolves an API-provided next link while ensuring
// the bearer token is never forwarded to another origin.
func digitalOceanPaginationURL(next string) (string, error) {
	next = strings.TrimSpace(next)
	if next == "" {
		return "", nil
	}

	apiBase, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("%w: invalid DigitalOcean API base URL", cloud.ErrAPIRequestFailed)
	}
	nextURL, err := url.Parse(next)
	if err != nil {
		return "", fmt.Errorf("%w: invalid DigitalOcean pagination URL", cloud.ErrAPIRequestFailed)
	}
	nextURL = apiBase.ResolveReference(nextURL)
	if !strings.EqualFold(nextURL.Scheme, apiBase.Scheme) || !strings.EqualFold(nextURL.Host, apiBase.Host) {
		return "", fmt.Errorf("%w: DigitalOcean pagination URL changed origin", cloud.ErrAPIRequestFailed)
	}
	return nextURL.String(), nil
}

// parseDigitalOceanInstanceID accepts only PrivateDeploy's canonical wrapper
// around a positive decimal DigitalOcean droplet ID. Requiring a byte-for-byte
// canonical representation rejects cross-provider IDs, whitespace aliases,
// path/query injection and leading-zero variants before any cloud request.
func parseDigitalOceanInstanceID(instanceID string) (int, error) {
	if instanceID == "" || instanceID != strings.TrimSpace(instanceID) || !strings.HasPrefix(instanceID, "cloud-do-") {
		return 0, cloud.ErrInstanceNotFound
	}
	rawID := strings.TrimPrefix(instanceID, "cloud-do-")
	if rawID == "" || (len(rawID) > 1 && rawID[0] == '0') {
		return 0, cloud.ErrInstanceNotFound
	}
	dropletID, err := strconv.Atoi(rawID)
	if err != nil || dropletID <= 0 || strconv.Itoa(dropletID) != rawID {
		return 0, cloud.ErrInstanceNotFound
	}
	return dropletID, nil
}

// CreateInstance creates a new DigitalOcean droplet.
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
	tuning.VLESSServerName = deploy.SelectVLESSRealityTarget(ctx, tuning.VLESSServerName)
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

	generateRealityKeyPair := p.generateRealityKeyPair
	if generateRealityKeyPair == nil {
		generateRealityKeyPair = deploy.GenerateRealityKeyPair
	}
	realityPrivateKey, realityPublicKey, err := generateRealityKeyPair()
	if err != nil {
		return nil, fmt.Errorf("failed to generate reality key pair before create: %w", err)
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

	// A running droplet cannot receive an SSH key retroactively. Establish and
	// durably retain the managed recovery key only after all local input and
	// payload preparation has succeeded, but before the billable POST. Creating
	// a droplet without it would make the advertised in-place repair impossible.
	managedSSHKeyID, _, managedSSHKeyFingerprint, err := p.ensureManagedSSHKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("prepare DigitalOcean managed SSH recovery key before create: %w", err)
	}
	if managedSSHKeyID == 0 || strings.TrimSpace(managedSSHKeyFingerprint) == "" {
		return nil, errors.New("prepare DigitalOcean managed SSH recovery key before create: incomplete key identity")
	}
	preparedRecord := nodeRecord{
		ManagedSSHKeyFingerprint: managedSSHKeyFingerprint,
		InstanceRecord: cloud.InstanceRecord{
			Plan:               opts.Plan,
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
		},
	}
	if strings.TrimSpace(opts.OperationJournalPath) != "" {
		if err := cloud.StoreCreateOperationProviderData(opts.OperationJournalPath, cloud.CreateOperationPrepared, digitalOceanCreateOperationData{
			Record: preparedRecord,
			Ports:  ports,
		}); err != nil {
			return nil, fmt.Errorf("journal DigitalOcean credentials before create: %w", err)
		}
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
	if strings.TrimSpace(opts.OperationID) != "" {
		createReq["tags"] = []string{cloud.CreateOperationTag("digitalocean", opts.OperationID)}
	}

	// Always attach the already-persisted managed key. Failure to prepare it
	// returned above, before the journal submission/billable POST boundary.
	sshKeyIDs := []interface{}{managedSSHKeyID}
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

	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	req.Header.Set("Content-Type", "application/json")
	if strings.TrimSpace(opts.OperationJournalPath) != "" {
		// Persist the irreversible boundary immediately before the one billable
		// POST. A restarted process can only query this operation's exact tag.
		if err := cloud.MarkCreateOperationSubmitted(opts.OperationJournalPath); err != nil {
			return nil, fmt.Errorf("journal DigitalOcean create submission: %w", err)
		}
	}

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: DigitalOcean transport failure; request was not retried: %v", cloud.ErrCreateOutcomePending, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= http.StatusInternalServerError {
			return nil, fmt.Errorf("%w: DigitalOcean create returned status %d; request was not retried: %s", cloud.ErrCreateOutcomePending, resp.StatusCode, string(body))
		}
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
		return nil, fmt.Errorf("%w: DigitalOcean accepted create but its response could not be decoded: %v", cloud.ErrCreateOutcomePending, err)
	}
	if result.Droplet.ID == 0 {
		return nil, fmt.Errorf("%w: DigitalOcean accepted create but returned no droplet id", cloud.ErrCreateOutcomePending)
	}

	instanceID := fmt.Sprintf("cloud-do-%d", result.Droplet.ID)
	p.beginInstanceCreate(instanceID)
	defer p.endInstanceCreate(instanceID)

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

	record := preparedRecord
	record.CreatedAt = result.Droplet.CreatedAt.Format(time.RFC3339)
	if strings.TrimSpace(opts.OperationJournalPath) != "" {
		if err := cloud.StoreCreateOperationProviderData(opts.OperationJournalPath, cloud.CreateOperationSubmitted, digitalOceanCreateOperationData{
			Record: record,
			Ports:  ports,
		}); err != nil {
			return nil, fmt.Errorf("%w: DigitalOcean droplet %s exists but its operation journal could not be updated: %v", cloud.ErrCreateOutcomePending, instanceID, err)
		}
		if err := cloud.MarkCreateOperationRemote(opts.OperationJournalPath, instanceID); err != nil {
			return nil, fmt.Errorf("%w: DigitalOcean droplet %s exists but its remote id could not be journaled: %v", cloud.ErrCreateOutcomePending, instanceID, err)
		}
	}

	if instance.IPv4 != "" {
		record.IPv4 = instance.IPv4
	}

	if instance.IPv6 != "" {
		record.IPv6 = instance.IPv6
	}

	if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
		records[instanceID] = record
		return true, nil
	}); err != nil {
		return nil, p.compensateUnrecordedInstance(instanceID, err)
	}

	warnings := make([]string, 0, 3)
	if err := p.configureInstanceFirewall(ctx, instanceID, result.Droplet.ID, ports); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to create/get firewall: %v\n", err)
		warnings = append(warnings, fmt.Sprintf("DigitalOcean firewall setup failed: %v", err))
	}

	readyTimeout := provutil.ParseServiceReadyTimeout(extra, defaultServiceReadyTimeout)
	readyPorts := []int{ssPort, vlessPort, trojanPort}
	if readyInstance, waitErr := p.waitForInstanceAndTCPPorts(ctx, instanceID, readyPorts, readyTimeout); waitErr != nil {
		fmt.Fprintf(os.Stderr, "[DigitalOceanProvider] Warning: %v\n", waitErr)
		warnings = append(warnings, fmt.Sprintf("instance/TCP readiness failed: %v", waitErr))
	} else if readyInstance != nil {
		instance = readyInstance
	}

	if probedInstance, probeErr := p.ensureProtocolReadinessWithRepair(ctx, instanceID, result.Droplet.ID, ports, extra); probeErr != nil {
		fmt.Fprintf(os.Stderr, "[DigitalOceanProvider] Warning: protocol readiness check failed: %v\n", probeErr)
		warnings = append(warnings, fmt.Sprintf("protocol readiness failed: %v", probeErr))
	} else if probedInstance != nil {
		instance = probedInstance
	}
	instance.LastDeployWarning = strings.Join(warnings, "; ")
	if instance.LastDeployWarning != "" {
		if err := p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
			record := records[instanceID]
			record.LastDeployWarning = instance.LastDeployWarning
			records[instanceID] = record
			return true, nil
		}); err != nil {
			return nil, fmt.Errorf("failed to persist deployment warning: %w", err)
		}
	}

	return instance, nil
}

// compensateUnrecordedInstance deletes a just-created droplet whose node record
// could not be persisted (the droplet would be unusable but keep billing), and
// returns an actionable error describing the outcome. It deliberately uses a
// fresh context so a canceled request context cannot strand the orphan. The
// returned error carries the instance ID but never credentials.
func (p *Provider) compensateUnrecordedInstance(instanceID string, persistErr error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Call the API directly instead of DestroyInstance: the latter also
	// rewrites the local records file, which is exactly what just failed.
	if _, delErr := p.deleteDropletRemote(ctx, instanceID); delErr != nil {
		return fmt.Errorf(
			"%w: failed to persist node record for digitalocean instance %s: %v; compensating delete also failed: %v — delete the droplet manually in the DigitalOcean console",
			cloud.ErrCreateOutcomePending,
			instanceID, persistErr, delErr,
		)
	}
	return fmt.Errorf(
		"failed to persist node record for digitalocean instance %s: %w; the droplet was deleted (rolled back) — retry the deploy",
		instanceID, persistErr,
	)
}

// dropletDefinitelyMissing guards destructive cleanup against eventually
// consistent list responses. Only an authoritative 404 permits removal of a
// node record or its owned firewall; every other response is "not confirmed".
func (p *Provider) dropletDefinitelyMissing(ctx context.Context, instanceID string) (bool, error) {
	dropletID, err := parseDigitalOceanInstanceID(instanceID)
	if err != nil {
		return false, cloud.ErrInstanceNotFound
	}
	actualID := strconv.Itoa(dropletID)
	apiKey, err := p.apiKey()
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := p.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	switch resp.StatusCode {
	case http.StatusNotFound:
		return true, nil
	case http.StatusOK:
		return false, nil
	default:
		return false, fmt.Errorf("%w: droplet confirmation status %d", cloud.ErrAPIRequestFailed, resp.StatusCode)
	}
}

// deleteDropletRemote deletes the droplet on the DigitalOcean side only,
// without touching local node records. It reports whether the droplet was
// already gone (404).
func (p *Provider) deleteDropletRemote(ctx context.Context, instanceID string) (notFound bool, err error) {
	dropletID, err := parseDigitalOceanInstanceID(instanceID)
	if err != nil {
		return false, cloud.ErrInstanceNotFound
	}
	actualID := strconv.Itoa(dropletID)

	apiKey, err := p.apiKey()
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, "DELETE", baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return false, err
	}

	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return true, nil
	}

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		return false, fmt.Errorf("%w: status %d, body: %s", cloud.ErrAPIRequestFailed, resp.StatusCode, string(body))
	}

	return false, nil
}

// DestroyInstance destroys a DigitalOcean droplet.
func (p *Provider) DestroyInstance(ctx context.Context, instanceID string) error {
	if _, err := parseDigitalOceanInstanceID(instanceID); err != nil {
		return cloud.ErrInstanceNotFound
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return fmt.Errorf("failed to load firewall ownership before destroying %s: %w", instanceID, err)
	}
	record, owned := records[instanceID]
	if !owned {
		return cloud.ErrInstanceNotFound
	}
	// A local record proves that this provider owns the action. An authoritative
	// per-droplet GET then distinguishes a live target from an already-gone one;
	// a transiently incomplete collection listing is never sufficient.
	missing, err := p.dropletDefinitelyMissing(ctx, instanceID)
	if err != nil {
		return err
	}
	if !missing {
		if _, err := p.deleteDropletRemote(ctx, instanceID); err != nil {
			return err
		}
	}
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := p.cleanupInstanceFirewalls(cleanupCtx, instanceID, record.FirewallOwnershipToken); err != nil {
		if markErr := p.markFirewallCleanupPending(instanceID); markErr != nil {
			return fmt.Errorf("droplet %s was deleted, but firewall cleanup failed: %v; failed to preserve hidden cleanup record: %w", instanceID, err, markErr)
		}
		return fmt.Errorf("droplet %s was deleted, but firewall cleanup failed: %w", instanceID, err)
	}
	return p.deleteNodeRecord(instanceID)
}

// GetInstance retrieves a specific DigitalOcean droplet.
func (p *Provider) GetInstance(ctx context.Context, instanceID string) (*cloud.Instance, error) {
	dropletID, err := parseDigitalOceanInstanceID(instanceID)
	if err != nil {
		return nil, cloud.ErrInstanceNotFound
	}
	records, err := p.loadNodeRecords()
	if err != nil {
		return nil, err
	}
	ownedRecord, owned := records[instanceID]
	if !owned {
		return nil, cloud.ErrInstanceNotFound
	}
	actualID := strconv.Itoa(dropletID)

	cfg, err := p.ensureConfig()
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/droplets/"+actualID, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		// Ownership was proven before the request. Never let an arbitrary
		// canonical droplet ID trigger local-record or firewall cleanup.
		if cleanupErr := p.cleanupInstanceFirewalls(ctx, instanceID, ownedRecord.FirewallOwnershipToken); cleanupErr != nil {
			_ = p.markFirewallCleanupPending(instanceID)
			return nil, fmt.Errorf("%w: firewall cleanup pending: %v", cloud.ErrInstanceNotFound, cleanupErr)
		}
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

	// Best-effort atomic merge into the local record (errors ignored, as
	// before): sync IP/plan/timestamps from the API and enrich the returned
	// instance with the locally stored credentials.
	_ = p.mutateNodeRecords(func(records map[string]nodeRecord) (bool, error) {
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
		if ensureManagedTLSDefaults(&record.InstanceRecord) {
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
		return updated, nil
	})

	return instance, nil
}
