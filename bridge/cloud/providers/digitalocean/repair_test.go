package digitalocean

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
)

func TestIsDigitalOceanTCPReadinessWarning(t *testing.T) {
	if !isDigitalOceanTCPReadinessWarning("instance/TCP readiness failed: pending tcp ports") {
		t.Fatal("expected TCP readiness warning to be refreshable")
	}

	for _, warning := range []string{
		"",
		"DigitalOcean firewall attachment failed: denied",
		"protocol readiness failed: proxy handshake failed",
		"instance/TCP readiness failed: timeout; protocol readiness failed: handshake",
		"repair failed: managed node credentials are missing",
	} {
		if isDigitalOceanTCPReadinessWarning(warning) {
			t.Fatalf("must not clear non-TCP warning after a TCP probe: %q", warning)
		}
	}
}

func TestRepairDigitalOceanServicePortsLeavesHealthyDropletAlone(t *testing.T) {
	instance := &cloud.Instance{ID: "cloud-do-42", IPv4: "203.0.113.10"}
	rerunCalls := 0
	waitCalls := 0

	got, err := repairDigitalOceanServicePorts(
		context.Background(),
		instance,
		instance.ID,
		[]int{443, 8443, 443, 0},
		digitalOceanServiceRepairOps{
			probe: func(_ context.Context, address string, ports []int, timeout time.Duration) []int {
				if address != instance.IPv4 {
					t.Fatalf("probe address = %q, want %q", address, instance.IPv4)
				}
				if !reflect.DeepEqual(ports, []int{443, 8443}) {
					t.Fatalf("probe ports = %v", ports)
				}
				if timeout != digitalOceanRepairQuickProbeTimeout {
					t.Fatalf("quick timeout = %s", timeout)
				}
				return nil
			},
			rerun: func(context.Context, string) error {
				rerunCalls++
				return nil
			},
			wait: func(context.Context, string, []int, time.Duration) (*cloud.Instance, error) {
				waitCalls++
				return nil, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("repairDigitalOceanServicePorts: %v", err)
	}
	if got != instance {
		t.Fatalf("healthy repair returned %#v, want original instance", got)
	}
	if rerunCalls != 0 || waitCalls != 0 {
		t.Fatalf("healthy droplet triggered rerun=%d wait=%d", rerunCalls, waitCalls)
	}
}

func TestRepairDigitalOceanServicePortsRerunsOnceAndUsesBoundedWait(t *testing.T) {
	instance := &cloud.Instance{ID: "cloud-do-42", IPv4: "203.0.113.10"}
	repaired := &cloud.Instance{ID: instance.ID, IPv4: instance.IPv4, Status: "active"}
	rerunCalls := 0
	waitCalls := 0

	got, err := repairDigitalOceanServicePorts(
		context.Background(),
		instance,
		instance.ID,
		[]int{443, 8443},
		digitalOceanServiceRepairOps{
			probe: func(context.Context, string, []int, time.Duration) []int {
				return []int{443}
			},
			rerun: func(_ context.Context, address string) error {
				rerunCalls++
				if address != instance.IPv4 {
					t.Fatalf("rerun address = %q, want %q", address, instance.IPv4)
				}
				return nil
			},
			wait: func(_ context.Context, instanceID string, ports []int, timeout time.Duration) (*cloud.Instance, error) {
				waitCalls++
				if instanceID != instance.ID {
					t.Fatalf("wait instance = %q, want %q", instanceID, instance.ID)
				}
				if !reflect.DeepEqual(ports, []int{443, 8443}) {
					t.Fatalf("wait ports = %v", ports)
				}
				if timeout != digitalOceanRepairReadyTimeout || timeout >= defaultServiceReadyTimeout {
					t.Fatalf("post-script timeout = %s, want short bounded timeout", timeout)
				}
				return repaired, nil
			},
		},
	)
	if err != nil {
		t.Fatalf("repairDigitalOceanServicePorts: %v", err)
	}
	if got != repaired {
		t.Fatalf("repair result = %#v, want %#v", got, repaired)
	}
	if rerunCalls != 1 || waitCalls != 1 {
		t.Fatalf("unhealthy droplet triggered rerun=%d wait=%d, want exactly one each", rerunCalls, waitCalls)
	}
}

func TestRepairDigitalOceanServicePortsHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	run := false

	_, err := repairDigitalOceanServicePorts(
		ctx,
		&cloud.Instance{ID: "cloud-do-42", IPv4: "203.0.113.10"},
		"cloud-do-42",
		[]int{443},
		digitalOceanServiceRepairOps{
			probe: func(context.Context, string, []int, time.Duration) []int { return []int{443} },
			rerun: func(context.Context, string) error { run = true; return nil },
			wait:  func(context.Context, string, []int, time.Duration) (*cloud.Instance, error) { return nil, nil },
		},
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("repair error = %v, want context.Canceled", err)
	}
	if run {
		t.Fatal("canceled repair executed the remote script")
	}
}

func TestRepairDigitalOceanServicePortsDoesNotWaitAfterRerunFailure(t *testing.T) {
	sentinel := errors.New("ssh unavailable")
	waitCalls := 0
	_, err := repairDigitalOceanServicePorts(
		context.Background(),
		&cloud.Instance{ID: "cloud-do-42", IPv4: "203.0.113.10"},
		"cloud-do-42",
		[]int{443},
		digitalOceanServiceRepairOps{
			probe: func(context.Context, string, []int, time.Duration) []int { return []int{443} },
			rerun: func(context.Context, string) error { return sentinel },
			wait: func(context.Context, string, []int, time.Duration) (*cloud.Instance, error) {
				waitCalls++
				return nil, nil
			},
		},
	)
	if !errors.Is(err, sentinel) {
		t.Fatalf("repair error = %v, want wrapped sentinel", err)
	}
	if waitCalls != 0 {
		t.Fatalf("wait called %d times after SSH rerun failure", waitCalls)
	}
}
