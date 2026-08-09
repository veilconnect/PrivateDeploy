package vultr

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

type vultrOwnershipRoundTripper func(*http.Request) (*http.Response, error)

func (roundTrip vultrOwnershipRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTrip(request)
}

func TestLifecycleRejectsUnownedOrNoncanonicalVultrIDsBeforeAPI(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	var requests atomic.Int32
	originalClient, originalBaseURL := vultrHTTPClient, vultrAPIBaseURL
	vultrHTTPClient = &http.Client{Transport: vultrOwnershipRoundTripper(func(*http.Request) (*http.Response, error) {
		requests.Add(1)
		return &http.Response{StatusCode: http.StatusInternalServerError, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	vultrAPIBaseURL = "https://vultr.invalid/v2"
	t.Cleanup(func() {
		vultrHTTPClient, vultrAPIBaseURL = originalClient, originalBaseURL
	})
	provider := New(&cloud.ProviderConfig{Provider: "vultr", APIKey: "test-token"})

	ids := []string{
		"11111111-2222-4333-8444-555555555555", // canonical, but unowned
		"11111111-2222-4333-8444-555555555555/../instances",
		"11111111-2222-4333-8444-555555555555?force=true",
		"11111111-2222-4333-8444-55555555555g",
		"11111111222243338444555555555555",
		"00000000-0000-0000-0000-000000000000",
		"cloud-do-123",
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
		t.Fatalf("rejected Vultr lifecycle IDs caused %d API requests, want 0", got)
	}
}
