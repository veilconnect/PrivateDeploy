package ssh

import (
	"context"
	"errors"
	"os"
	"testing"

	"privatedeploy/bridge/cloud"
)

func TestLifecycleRequiresExactSSHNodeRecord(t *testing.T) {
	t.Setenv("PRIVATEDEPLOY_BASE_PATH", t.TempDir())
	provider := New(&cloud.ProviderConfig{Provider: "ssh"})
	for _, instanceID := range []string{
		"cloud-ssh-unowned-1-deadbeef",
		" cloud-ssh-unowned-1-deadbeef",
		"cloud-ssh-unowned/../victim",
		"cloud-do-123",
	} {
		if err := provider.DestroyInstance(context.Background(), instanceID); !errors.Is(err, cloud.ErrInstanceNotFound) {
			t.Fatalf("DestroyInstance(%q) error=%v, want ErrInstanceNotFound", instanceID, err)
		}
		if instance, err := provider.RepairInstance(context.Background(), instanceID); instance != nil || !errors.Is(err, cloud.ErrInstanceNotFound) {
			t.Fatalf("RepairInstance(%q)=(%#v,%v), want nil ErrInstanceNotFound", instanceID, instance, err)
		}
	}
	if _, err := os.Stat(provider.nodesPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejected SSH lifecycle IDs mutated node state: %v", err)
	}
}
