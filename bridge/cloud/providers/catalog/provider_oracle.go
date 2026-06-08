package catalog

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

func (p *Provider) oracleListRegions(ctx context.Context) ([]cloud.Region, error) {
	out, err := p.oracleCLI(ctx, "iam", "region", "list", "--all")
	if err != nil {
		return nil, err
	}
	var payload struct {
		Data []struct {
			Name string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, err
	}
	regions := make([]cloud.Region, 0, len(payload.Data))
	for _, item := range payload.Data {
		regionID := strings.TrimSpace(item.Name)
		if regionID == "" {
			continue
		}
		city, country := oracleRegionLocation(regionID)
		regions = append(regions, cloud.Region{
			ID:        regionID,
			City:      firstNonEmpty(city, regionID),
			Country:   firstNonEmpty(country, "Unknown"),
			Continent: continentFromCountry(country),
		})
	}
	if len(regions) == 0 {
		return nil, fmt.Errorf("oracle returned no regions")
	}
	return regions, nil
}

func (p *Provider) oracleListPlans(_ context.Context) ([]cloud.Plan, error) {
	return append([]cloud.Plan(nil), p.plans...), nil
}

func (p *Provider) oracleExtra(cfg *cloud.ProviderConfig, keys ...string) string {
	if cfg == nil {
		return ""
	}
	obj := parseAPIKeyObject(cfg.APIKey)
	for _, key := range keys {
		if v := strings.TrimSpace(cfg.Extra[key]); v != "" {
			return v
		}
		if v := lookupMapValue(obj, key); v != "" {
			return v
		}
	}
	return ""
}

func (p *Provider) oracleCLI(ctx context.Context, args ...string) ([]byte, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return nil, err
	}

	fullArgs := append([]string(nil), args...)
	if !slices.Contains(fullArgs, "--output") {
		fullArgs = append(fullArgs, "--output", "json")
	}
	if !slices.Contains(fullArgs, "--profile") {
		profile := p.oracleExtra(cfg, "profile", "oracle_profile")
		if profile == "" {
			raw := strings.TrimSpace(cfg.APIKey)
			if raw != "" && !strings.HasPrefix(raw, "{") {
				profile = raw
			}
		}
		if profile == "" {
			profile = "DEFAULT"
		}
		fullArgs = append(fullArgs, "--profile", profile)
	}

	runCtx := ctx
	var cancel context.CancelFunc
	if _, ok := ctx.Deadline(); !ok {
		runCtx, cancel = context.WithTimeout(ctx, catalogDefaultOracleTimeout)
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, "oci", fullArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("oci %s failed: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func (p *Provider) oracleListInstances(ctx context.Context) ([]remoteInstance, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return nil, err
	}
	compartmentID := p.oracleExtra(cfg, "compartmentId", "compartment_id", "compartment_ocid")
	if compartmentID == "" {
		return nil, fmt.Errorf("oracle requires compartment id: set extra.compartmentId")
	}

	out, err := p.oracleCLI(ctx, "compute", "instance", "list", "--all", "--compartment-id", compartmentID)
	if err != nil {
		return nil, err
	}
	var payload struct {
		Data []struct {
			ID                 string `json:"id"`
			DisplayName        string `json:"display-name"`
			LifecycleState     string `json:"lifecycle-state"`
			Shape              string `json:"shape"`
			TimeCreated        string `json:"time-created"`
			AvailabilityDomain string `json:"availability-domain"`
			Region             string `json:"region"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, err
	}
	instances := make([]remoteInstance, 0, len(payload.Data))
	for _, item := range payload.Data {
		id := strings.TrimSpace(item.ID)
		if id == "" {
			continue
		}
		ipv4, _ := p.oraclePublicIP(ctx, id)
		region := firstNonEmpty(strings.TrimSpace(item.Region), oracleRegionFromAD(item.AvailabilityDomain))
		instances = append(instances, remoteInstance{
			RawID:     id,
			ID:        p.cloudID(id),
			Label:     firstNonEmpty(item.DisplayName, "node"),
			Status:    strings.ToLower(strings.TrimSpace(item.LifecycleState)),
			Region:    region,
			Plan:      strings.TrimSpace(item.Shape),
			IPv4:      ipv4,
			CreatedAt: parseRFC3339(item.TimeCreated),
		})
	}
	return instances, nil
}

func (p *Provider) oracleGetInstance(ctx context.Context, remoteID string) (remoteInstance, error) {
	id := strings.TrimSpace(remoteID)
	if id == "" {
		return remoteInstance{}, cloud.ErrInstanceNotFound
	}
	out, err := p.oracleCLI(ctx, "compute", "instance", "get", "--instance-id", id)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "notfound") || strings.Contains(err.Error(), "404") {
			return remoteInstance{}, cloud.ErrInstanceNotFound
		}
		return remoteInstance{}, err
	}
	var payload struct {
		Data struct {
			ID                 string `json:"id"`
			DisplayName        string `json:"display-name"`
			LifecycleState     string `json:"lifecycle-state"`
			Shape              string `json:"shape"`
			TimeCreated        string `json:"time-created"`
			AvailabilityDomain string `json:"availability-domain"`
			Region             string `json:"region"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return remoteInstance{}, err
	}
	ipv4, _ := p.oraclePublicIP(ctx, id)
	region := firstNonEmpty(strings.TrimSpace(payload.Data.Region), oracleRegionFromAD(payload.Data.AvailabilityDomain))
	return remoteInstance{
		RawID:     id,
		ID:        p.cloudID(id),
		Label:     firstNonEmpty(payload.Data.DisplayName, "node"),
		Status:    strings.ToLower(strings.TrimSpace(payload.Data.LifecycleState)),
		Region:    region,
		Plan:      strings.TrimSpace(payload.Data.Shape),
		IPv4:      ipv4,
		CreatedAt: parseRFC3339(payload.Data.TimeCreated),
	}, nil
}

func (p *Provider) oraclePublicIP(ctx context.Context, instanceID string) (string, error) {
	out, err := p.oracleCLI(ctx, "compute", "instance", "list-vnics", "--instance-id", instanceID)
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			IsPrimary bool   `json:"is-primary"`
			PublicIP  string `json:"public-ip"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	for _, item := range payload.Data {
		if item.IsPrimary && strings.TrimSpace(item.PublicIP) != "" {
			return strings.TrimSpace(item.PublicIP), nil
		}
	}
	for _, item := range payload.Data {
		if strings.TrimSpace(item.PublicIP) != "" {
			return strings.TrimSpace(item.PublicIP), nil
		}
	}
	return "", nil
}

func (p *Provider) oracleCreateInstance(ctx context.Context, label, region, plan, userData string) (remoteInstance, error) {
	cfg, err := p.getEffectiveConfig()
	if err != nil {
		return remoteInstance{}, err
	}
	compartmentID := p.oracleExtra(cfg, "compartmentId", "compartment_id", "compartment_ocid")
	if compartmentID == "" {
		return remoteInstance{}, fmt.Errorf("oracle create requires extra.compartmentId")
	}
	subnetID := p.oracleExtra(cfg, "subnetId", "subnet_id", "subnet_ocid")
	if subnetID == "" {
		return remoteInstance{}, fmt.Errorf("oracle create requires extra.subnetId")
	}

	shape := strings.TrimSpace(plan)
	if shape == "" {
		shape = "VM.Standard.E2.1.Micro"
	}
	availabilityDomain := p.oracleExtra(cfg, "availabilityDomain", "availability_domain")
	if availabilityDomain == "" {
		ad, err := p.oracleResolveAvailabilityDomain(ctx, compartmentID)
		if err != nil {
			return remoteInstance{}, err
		}
		availabilityDomain = ad
	}
	imageID := p.oracleExtra(cfg, "imageId", "image_id", "image_ocid")
	if imageID == "" {
		imageID, err = p.oracleResolveImageID(ctx, compartmentID)
		if err != nil {
			return remoteInstance{}, err
		}
	}

	metaRaw, _ := json.Marshal(map[string]string{"user_data": base64.StdEncoding.EncodeToString([]byte(userData))})
	args := []string{
		"compute", "instance", "launch",
		"--compartment-id", compartmentID,
		"--availability-domain", availabilityDomain,
		"--shape", shape,
		"--subnet-id", subnetID,
		"--image-id", imageID,
		"--display-name", label,
		"--assign-public-ip", "true",
		"--metadata", string(metaRaw),
	}
	if strings.Contains(strings.ToLower(shape), ".flex") {
		shapeCfg := map[string]any{
			"ocpus":         1,
			"memory_in_gbs": 6,
		}
		if strings.Contains(strings.ToLower(shape), "standard3") {
			shapeCfg["memory_in_gbs"] = 8
		}
		if ocpus := p.oracleExtra(cfg, "ocpus", "oracle_ocpus"); ocpus != "" {
			if v, err := strconv.ParseFloat(ocpus, 64); err == nil && v > 0 {
				shapeCfg["ocpus"] = v
			}
		}
		if mem := p.oracleExtra(cfg, "memoryInGBs", "memory_in_gbs", "oracle_memory_gbs"); mem != "" {
			if v, err := strconv.ParseFloat(mem, 64); err == nil && v > 0 {
				shapeCfg["memory_in_gbs"] = v
			}
		}
		shapeCfgRaw, _ := json.Marshal(shapeCfg)
		args = append(args, "--shape-config", string(shapeCfgRaw))
	}

	out, err := p.oracleCLI(ctx, args...)
	if err != nil {
		return remoteInstance{}, err
	}
	var payload struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return remoteInstance{}, err
	}
	id := strings.TrimSpace(payload.Data.ID)
	if id == "" {
		return remoteInstance{}, fmt.Errorf("oracle create did not return instance id")
	}
	if inst, err := p.oracleGetInstance(ctx, id); err == nil {
		return inst, nil
	}
	return remoteInstance{
		RawID:     id,
		ID:        p.cloudID(id),
		Label:     label,
		Status:    "provisioning",
		Region:    region,
		Plan:      shape,
		CreatedAt: time.Now().UTC(),
	}, nil
}

func (p *Provider) oracleResolveAvailabilityDomain(ctx context.Context, compartmentID string) (string, error) {
	out, err := p.oracleCLI(ctx, "iam", "availability-domain", "list", "--compartment-id", compartmentID)
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			Name string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	if len(payload.Data) == 0 || strings.TrimSpace(payload.Data[0].Name) == "" {
		return "", fmt.Errorf("oracle returned no availability domains")
	}
	return strings.TrimSpace(payload.Data[0].Name), nil
}

func (p *Provider) oracleResolveImageID(ctx context.Context, compartmentID string) (string, error) {
	out, err := p.oracleCLI(ctx, "compute", "image", "list", "--all", "--compartment-id", compartmentID, "--operating-system", "Canonical Ubuntu", "--sort-by", "TIMECREATED", "--sort-order", "DESC")
	if err != nil {
		return "", err
	}
	var payload struct {
		Data []struct {
			ID               string `json:"id"`
			DisplayName      string `json:"display-name"`
			LifecycleState   string `json:"lifecycle-state"`
			OperatingSystem  string `json:"operating-system"`
			OperatingVersion string `json:"operating-system-version"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return "", err
	}
	pick := ""
	for _, image := range payload.Data {
		if strings.TrimSpace(image.ID) == "" {
			continue
		}
		if strings.ToUpper(strings.TrimSpace(image.LifecycleState)) != "AVAILABLE" {
			continue
		}
		if strings.Contains(strings.ToLower(image.DisplayName), "ubuntu") && strings.Contains(image.OperatingVersion, "22") {
			return strings.TrimSpace(image.ID), nil
		}
		if pick == "" {
			pick = strings.TrimSpace(image.ID)
		}
	}
	if pick == "" {
		return "", fmt.Errorf("oracle returned no usable images")
	}
	return pick, nil
}

func (p *Provider) oracleDestroyInstance(ctx context.Context, remoteID string) error {
	id := strings.TrimSpace(remoteID)
	if id == "" {
		return cloud.ErrInstanceNotFound
	}
	_, err := p.oracleCLI(ctx, "compute", "instance", "terminate", "--instance-id", id, "--force")
	if err != nil && !(strings.Contains(strings.ToLower(err.Error()), "notfound") || strings.Contains(err.Error(), "404")) {
		return err
	}
	return nil
}
