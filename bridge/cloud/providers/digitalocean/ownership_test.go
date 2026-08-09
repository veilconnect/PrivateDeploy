package digitalocean

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"privatedeploy/bridge/cloud"
)

type digitalOceanOwnershipRoundTripper func(*http.Request) (*http.Response, error)

func (roundTrip digitalOceanOwnershipRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTrip(request)
}

func TestLifecycleRejectsUnownedOrNoncanonicalDigitalOceanIDsBeforeAPI(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	var requests atomic.Int32
	provider := New(&cloud.ProviderConfig{Provider: "digitalocean", APIKey: "test-token"})
	provider.client = &http.Client{Transport: digitalOceanOwnershipRoundTripper(func(*http.Request) (*http.Response, error) {
		requests.Add(1)
		return &http.Response{StatusCode: http.StatusInternalServerError, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}

	ids := []string{
		"cloud-do-123", // canonical, but not owned by this provider state
		"cloud-do-0123",
		"cloud-do-1/../2",
		"cloud-do-1?force=true",
		" cloud-do-1",
		"cloud-do-0",
		"11111111-2222-4333-8444-555555555555", // Vultr collision
	}
	for _, instanceID := range ids {
		if instance, err := provider.GetInstance(context.Background(), instanceID); instance != nil || !errors.Is(err, cloud.ErrInstanceNotFound) {
			t.Fatalf("GetInstance(%q)=(%#v,%v), want nil ErrInstanceNotFound", instanceID, instance, err)
		}
		if err := provider.DestroyInstance(context.Background(), instanceID); !errors.Is(err, cloud.ErrInstanceNotFound) {
			t.Fatalf("DestroyInstance(%q) error=%v, want ErrInstanceNotFound", instanceID, err)
		}
		if instance, err := provider.RepairInstance(context.Background(), instanceID); instance != nil || !errors.Is(err, cloud.ErrInstanceNotFound) {
			t.Fatalf("RepairInstance(%q)=(%#v,%v), want nil ErrInstanceNotFound", instanceID, instance, err)
		}
	}
	if got := requests.Load(); got != 0 {
		t.Fatalf("rejected DigitalOcean lifecycle IDs caused %d API requests, want 0", got)
	}
}
