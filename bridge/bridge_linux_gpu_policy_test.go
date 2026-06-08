package bridge

import "testing"

func TestResolveWebviewGpuPolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		osName     string
		rawConfig  []byte
		configured int
		want       int
	}{
		{
			name:       "non linux keeps configured value",
			osName:     "windows",
			rawConfig:  []byte("webviewGpuPolicy: 1\n"),
			configured: webviewGpuPolicyOnDemand,
			want:       webviewGpuPolicyOnDemand,
		},
		{
			name:       "linux defaults to never when unset",
			osName:     "linux",
			rawConfig:  []byte("theme: auto\n"),
			configured: webviewGpuPolicyAlways,
			want:       webviewGpuPolicyNever,
		},
		{
			name:       "linux migrates ondemand to never",
			osName:     "linux",
			rawConfig:  []byte("webviewGpuPolicy: 1\n"),
			configured: webviewGpuPolicyOnDemand,
			want:       webviewGpuPolicyNever,
		},
		{
			name:       "linux keeps always",
			osName:     "linux",
			rawConfig:  []byte("webviewGpuPolicy: 0\n"),
			configured: webviewGpuPolicyAlways,
			want:       webviewGpuPolicyAlways,
		},
		{
			name:       "linux keeps never",
			osName:     "linux",
			rawConfig:  []byte("webviewGpuPolicy: 2\n"),
			configured: webviewGpuPolicyNever,
			want:       webviewGpuPolicyNever,
		},
		{
			name:       "linux sanitizes invalid values",
			osName:     "linux",
			rawConfig:  []byte("webviewGpuPolicy: 99\n"),
			configured: 99,
			want:       webviewGpuPolicyNever,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := resolveWebviewGpuPolicy(tc.osName, tc.rawConfig, tc.configured)
			if got != tc.want {
				t.Fatalf("resolveWebviewGpuPolicy(%q, %q, %d) = %d, want %d", tc.osName, tc.rawConfig, tc.configured, got, tc.want)
			}
		})
	}
}

func TestBuildPlatformCapabilities(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		osName     string
		assertions func(t *testing.T, capabilities PlatformCapabilities)
	}{
		{
			name:   "windows capabilities",
			osName: "windows",
			assertions: func(t *testing.T, capabilities PlatformCapabilities) {
				t.Helper()
				if !capabilities.TraySupported {
					t.Fatal("expected tray support on windows")
				}
				if capabilities.ShowMainWindowFromTray {
					t.Fatal("expected show-main-window tray action disabled on windows")
				}
				if !capabilities.StartupLaunchSupported || !capabilities.StartupDelaySupported {
					t.Fatal("expected startup launch and delay support on windows")
				}
				if !capabilities.AdminElevationSupported {
					t.Fatal("expected admin elevation support on windows")
				}
				if capabilities.KernelGrantPermissionSupported {
					t.Fatal("expected kernel grant permission support disabled on windows")
				}
			},
		},
		{
			name:   "linux capabilities",
			osName: "linux",
			assertions: func(t *testing.T, capabilities PlatformCapabilities) {
				t.Helper()
				if !capabilities.ConfigurableWebviewGpuPolicy {
					t.Fatal("expected configurable webview gpu policy on linux")
				}
				if !capabilities.KernelGrantPermissionSupported {
					t.Fatal("expected kernel grant permission support on linux")
				}
				if capabilities.StartupLaunchSupported || capabilities.AdminElevationSupported {
					t.Fatal("expected linux startup/admin capabilities to remain disabled")
				}
			},
		},
		{
			name:   "darwin capabilities",
			osName: "darwin",
			assertions: func(t *testing.T, capabilities PlatformCapabilities) {
				t.Helper()
				if !capabilities.TraySupported || !capabilities.ShowMainWindowFromTray {
					t.Fatal("expected tray support on macOS")
				}
				if !capabilities.KernelGrantPermissionSupported {
					t.Fatal("expected kernel grant permission support on macOS")
				}
				if capabilities.ConfigurableWebviewGpuPolicy {
					t.Fatal("did not expect configurable webview gpu policy on macOS")
				}
			},
		},
		{
			name:   "unknown platform fallback",
			osName: "freebsd",
			assertions: func(t *testing.T, capabilities PlatformCapabilities) {
				t.Helper()
				if capabilities.TraySupported || capabilities.SystemProxySupported {
					t.Fatal("expected unsupported platform fallback to disable tray and system proxy")
				}
			},
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			tc.assertions(t, buildPlatformCapabilities(tc.osName))
		})
	}
}
