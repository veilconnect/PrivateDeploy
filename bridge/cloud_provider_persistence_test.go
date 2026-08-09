package bridge

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/defaults"
)

func newProviderPersistenceTestApp(basePath string) *App {
	return &App{
		CloudManager:           cloud.NewManager(context.Background(), defaults.Registry()),
		cloudOperationBasePath: basePath,
	}
}

func writeLegacyProviderState(t *testing.T, basePath, filename string, modified time.Time) {
	t.Helper()
	path := filepath.Join(basePath, "data", "cloud", filename)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func assertActiveProvider(t *testing.T, app *App, want string) {
	t.Helper()
	provider, err := app.CloudManager.GetActiveProvider()
	if err != nil {
		t.Fatal(err)
	}
	if got := provider.Name(); got != want {
		t.Fatalf("active provider = %q, want %q", got, want)
	}
}

func TestLegacyProviderMigrationSelectsUniqueDigitalOceanState(t *testing.T) {
	basePath := t.TempDir()
	writeLegacyProviderState(t, basePath, "digitalocean-nodes.json", time.Now().Add(-time.Hour))
	app := newProviderPersistenceTestApp(basePath)

	if err := app.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatal(err)
	}
	assertActiveProvider(t, app, "digitalocean")
	raw, err := os.ReadFile(app.activeCloudProviderPath())
	if err != nil {
		t.Fatal(err)
	}
	if got := string(raw); got != "digitalocean\n" {
		t.Fatalf("migrated marker = %q", got)
	}
}

func TestLegacyProviderMigrationSelectsNewestProviderState(t *testing.T) {
	basePath := t.TempDir()
	anchor := time.Now().Add(-2 * time.Hour)
	writeLegacyProviderState(t, basePath, "vultr-config.json", anchor)
	writeLegacyProviderState(t, basePath, "digitalocean-nodes.json", anchor.Add(time.Hour))
	app := newProviderPersistenceTestApp(basePath)

	if err := app.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatal(err)
	}
	assertActiveProvider(t, app, "digitalocean")
}

func TestLegacyProviderMigrationTiedStateUsesFallback(t *testing.T) {
	basePath := t.TempDir()
	modified := time.Now().Add(-time.Hour)
	writeLegacyProviderState(t, basePath, "vultr-config.json", modified)
	writeLegacyProviderState(t, basePath, "digitalocean-nodes.json", modified)
	app := newProviderPersistenceTestApp(basePath)

	if err := app.restoreActiveCloudProvider("ssh"); err != nil {
		t.Fatal(err)
	}
	assertActiveProvider(t, app, "ssh")
}

func TestLegacyProviderMigrationWithoutStatePersistsFallback(t *testing.T) {
	basePath := t.TempDir()
	app := newProviderPersistenceTestApp(basePath)

	if err := app.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatal(err)
	}
	assertActiveProvider(t, app, "vultr")
	raw, err := os.ReadFile(app.activeCloudProviderPath())
	if err != nil {
		t.Fatal(err)
	}
	if got := string(raw); got != "vultr\n" {
		t.Fatalf("fallback marker = %q", got)
	}
}

func TestActiveProviderMarkerWinsOverNewerLegacyState(t *testing.T) {
	basePath := t.TempDir()
	writeLegacyProviderState(t, basePath, "digitalocean-nodes.json", time.Now())
	app := newProviderPersistenceTestApp(basePath)
	if err := app.persistActiveCloudProviderChoice("vultr"); err != nil {
		t.Fatal(err)
	}

	if err := app.restoreActiveCloudProvider("digitalocean"); err != nil {
		t.Fatal(err)
	}
	assertActiveProvider(t, app, "vultr")
}

func TestActiveCloudProviderPersistsAcrossManagerRestart(t *testing.T) {
	basePath := t.TempDir()

	first := newProviderPersistenceTestApp(basePath)
	if err := first.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatalf("restore initial provider: %v", err)
	}
	if _, err := first.SetCloudProviderTyped("digitalocean"); err != nil {
		t.Fatalf("select DigitalOcean: %v", err)
	}

	choicePath := filepath.Join(basePath, "data", "cloud", activeCloudProviderFile)
	info, err := os.Stat(choicePath)
	if err != nil {
		t.Fatalf("stat persisted provider choice: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("provider choice permissions = %#o, want 0600", got)
	}

	// A fresh manager models a full application restart. The persisted choice
	// must win over the historical Vultr fallback so the next config/list calls
	// address the same provider slots the user selected before restarting.
	second := newProviderPersistenceTestApp(basePath)
	if err := second.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatalf("restore provider after restart: %v", err)
	}
	provider, err := second.CloudManager.GetActiveProvider()
	if err != nil {
		t.Fatalf("get restored provider: %v", err)
	}
	if got, want := provider.Name(), "digitalocean"; got != want {
		t.Fatalf("restored provider = %q, want %q", got, want)
	}
}

func TestActiveCloudProviderInvalidChoiceFallsBackWithoutRewriting(t *testing.T) {
	basePath := t.TempDir()
	choicePath := filepath.Join(basePath, "data", "cloud", activeCloudProviderFile)
	if err := os.MkdirAll(filepath.Dir(choicePath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(choicePath, []byte("oracle\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	app := newProviderPersistenceTestApp(basePath)
	if err := app.restoreActiveCloudProvider("vultr"); err != nil {
		t.Fatalf("restore fallback provider: %v", err)
	}
	provider, err := app.CloudManager.GetActiveProvider()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := provider.Name(), "vultr"; got != want {
		t.Fatalf("fallback provider = %q, want %q", got, want)
	}

	// Invalid state is evidence worth preserving for diagnostics. Merely
	// restoring a safe fallback must not silently overwrite it.
	raw, err := os.ReadFile(choicePath)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(raw), "oracle\n"; got != want {
		t.Fatalf("invalid choice was unexpectedly rewritten: got %q, want %q", got, want)
	}
}

func TestSetCloudProviderRollsBackWhenChoiceCannotBePersisted(t *testing.T) {
	parent := t.TempDir()
	basePath := filepath.Join(parent, "not-a-directory")
	if err := os.WriteFile(basePath, []byte("blocks mkdir"), 0o600); err != nil {
		t.Fatal(err)
	}

	app := newProviderPersistenceTestApp(basePath)
	if err := app.CloudManager.SetActiveProvider("vultr"); err != nil {
		t.Fatal(err)
	}
	if _, err := app.SetCloudProviderTyped("digitalocean"); err == nil {
		t.Fatal("provider switch succeeded even though its durable choice could not be written")
	}
	provider, err := app.CloudManager.GetActiveProvider()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := provider.Name(), "vultr"; got != want {
		t.Fatalf("provider after failed persistence = %q, want rolled-back %q", got, want)
	}
}
