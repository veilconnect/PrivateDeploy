package catalog

import (
	"context"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestCatalogProvidersBasicMetadataAndCatalogs(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		new  func(*cloud.ProviderConfig) *Provider
	}{
		{name: "hetzner", new: NewHetzner},
		{name: "linode", new: NewLinode},
		{name: "scaleway", new: NewScaleway},
		{name: "upcloud", new: NewUpCloud},
		{name: "contabo", new: NewContabo},
		{name: "oracle", new: NewOracle},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			p := tt.new(nil)
			if p.Name() != tt.name {
				t.Fatalf("provider name mismatch: want %q got %q", tt.name, p.Name())
			}

			if err := p.ValidateConfig(&cloud.ProviderConfig{Provider: tt.name}); err == nil {
				t.Fatalf("expected missing api key validation error")
			}

			if err := p.ValidateConfig(&cloud.ProviderConfig{Provider: tt.name, APIKey: "test-key"}); err != nil {
				t.Fatalf("unexpected validate error: %v", err)
			}

			regions, err := p.ListRegions(context.Background())
			if err != nil {
				t.Fatalf("list regions failed: %v", err)
			}
			if len(regions) == 0 {
				t.Fatalf("expected regions to be non-empty")
			}

			plans, err := p.ListPlans(context.Background(), "")
			if err != nil {
				t.Fatalf("list plans failed: %v", err)
			}
			if len(plans) == 0 {
				t.Fatalf("expected plans to be non-empty")
			}

			avail, err := p.ListAvailability(context.Background(), regions[0].ID)
			if err != nil {
				t.Fatalf("list availability failed: %v", err)
			}
			if len(avail) == 0 {
				t.Fatalf("expected availability to be non-empty")
			}
		})
	}
}

func TestCatalogProvidersSupportLifecycle(t *testing.T) {
	t.Parallel()

	providers := []*Provider{
		NewHetzner(nil),
		NewLinode(nil),
		NewScaleway(nil),
		NewUpCloud(nil),
		NewContabo(nil),
		NewOracle(nil),
	}
	for _, p := range providers {
		if !p.supportsLifecycle() {
			t.Fatalf("expected provider %s to support lifecycle", p.Name())
		}
	}
}

func TestScopedRemoteIDRoundTrip(t *testing.T) {
	t.Parallel()

	raw := scopedRemoteID("fr-par-1", "abc-123")
	scope, id, ok := parseScopedRemoteID(raw)
	if !ok {
		t.Fatalf("expected scoped id to parse")
	}
	if scope != "fr-par-1" || id != "abc-123" {
		t.Fatalf("unexpected scoped parse result: scope=%q id=%q", scope, id)
	}
}

func TestUpCloudCredentialsFromAPIKey(t *testing.T) {
	t.Parallel()

	username, password, err := upcloudCredentials(&cloud.ProviderConfig{
		Provider: "upcloud",
		APIKey:   "api-user:api-password",
		Extra:    map[string]string{},
	})
	if err != nil {
		t.Fatalf("unexpected credentials parse error: %v", err)
	}
	if username != "api-user" || password != "api-password" {
		t.Fatalf("unexpected credentials parse result: username=%q password=%q", username, password)
	}
}

func TestContaboCredentialsFromAPIKeyPipe(t *testing.T) {
	t.Parallel()

	p := NewContabo(nil)
	creds, err := p.contaboCredentials(&cloud.ProviderConfig{
		Provider: "contabo",
		APIKey:   "cid|csecret|user@example.com|pass123",
		Extra:    map[string]string{},
	})
	if err != nil {
		t.Fatalf("unexpected contabo credentials error: %v", err)
	}
	if creds.ClientID != "cid" || creds.ClientSecret != "csecret" || creds.Username != "user@example.com" || creds.Password != "pass123" {
		t.Fatalf("unexpected contabo credentials %+v", creds)
	}
}
