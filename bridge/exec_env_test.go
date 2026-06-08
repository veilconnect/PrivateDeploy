package bridge

import (
	"os/exec"
	"strings"
	"testing"
)

func TestBuildCmdEnvInheritsSystemEnvWhenCustomEnvIsSet(t *testing.T) {
	custom := map[string]string{
		"ENABLE_DEPRECATED_LEGACY_DNS_SERVERS":      "true",
		"ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER": "true",
	}

	env := buildCmdEnv(custom)
	if env == nil {
		t.Fatal("expected non-nil env when custom env is provided")
	}

	// The result must contain the custom keys.
	envMap := make(map[string]bool)
	for _, entry := range env {
		parts := strings.SplitN(entry, "=", 2)
		envMap[parts[0]] = true
	}

	for key := range custom {
		if !envMap[key] {
			t.Errorf("custom env key %q missing from result", key)
		}
	}

	// The result must also contain standard system env vars (PATH always exists).
	if !envMap["PATH"] && !envMap["Path"] {
		t.Error("system PATH missing — custom env replaced instead of extending the environment")
	}
}

func TestBuildCmdEnvReturnsNilWhenNoCustomEnv(t *testing.T) {
	env := buildCmdEnv(nil)
	if env != nil {
		t.Fatal("expected nil env when no custom env is provided")
	}

	env = buildCmdEnv(map[string]string{})
	if env != nil {
		t.Fatal("expected nil env when custom env map is empty")
	}
}

// TestExecPreservesSystemEnvInSubprocess is an integration test that actually
// spawns a subprocess to verify system environment variables are present.
func TestExecPreservesSystemEnvInSubprocess(t *testing.T) {
	custom := map[string]string{
		"MY_CUSTOM_VAR": "hello",
	}

	env := buildCmdEnv(custom)

	// Use "env" (or "printenv") to dump the child's environment.
	cmd := exec.Command("env")
	cmd.Env = env

	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("failed to run env command: %v", err)
	}

	output := string(out)

	if !strings.Contains(output, "MY_CUSTOM_VAR=hello") {
		t.Error("custom variable MY_CUSTOM_VAR not found in subprocess environment")
	}

	// PATH should be inherited from the parent.
	if !strings.Contains(output, "PATH=") {
		t.Error("system PATH not found in subprocess environment — env was replaced, not extended")
	}
}
