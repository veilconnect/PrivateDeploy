package digitalocean

import (
	"path/filepath"
	"testing"
)

func TestSingboxBinaryCandidatesWindowsIncludeExe(t *testing.T) {
	basePath := `C:\PrivateDeploy`
	candidates := singboxBinaryCandidates(basePath, "windows")

	if len(candidates) == 0 {
		t.Fatal("expected candidates for windows base path")
	}

	for _, candidate := range candidates {
		if filepath.Ext(candidate) != ".exe" {
			t.Fatalf("candidate %q is missing .exe suffix", candidate)
		}
	}
}

func TestSingboxBinaryCandidatesLinuxStayExtensionless(t *testing.T) {
	basePath := "/opt/privatedeploy"
	candidates := singboxBinaryCandidates(basePath, "linux")

	if len(candidates) == 0 {
		t.Fatal("expected candidates for linux base path")
	}

	for _, candidate := range candidates {
		if filepath.Ext(candidate) != "" {
			t.Fatalf("candidate %q should not have a file extension", candidate)
		}
	}
}
