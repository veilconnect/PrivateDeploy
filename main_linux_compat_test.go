package main

import (
	"os"
	"testing"

	"privatedeploy/bridge"
)

func TestConfigureLinuxWebKitCompatibility(t *testing.T) {
	if bridge.Env.OS != "linux" {
		t.Skip("Linux-only compatibility policy")
	}

	t.Setenv("WEBKIT_FORCE_COMPOSITING_MODE", "1")
	t.Setenv("WEBKIT_FORCE_DMABUF_RENDERER", "1")
	t.Setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "0")
	t.Setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "0")
	t.Setenv("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "0")
	t.Setenv("LIBGL_ALWAYS_SOFTWARE", "0")
	t.Setenv("PRIVATEDEPLOY_ALLOW_NVIDIA_EGL", "0")

	configureLinuxWebKitCompatibility()

	if got := os.Getenv("WEBKIT_DISABLE_COMPOSITING_MODE"); got != "1" {
		t.Fatalf("WEBKIT_DISABLE_COMPOSITING_MODE=%q, want 1", got)
	}
	if got := os.Getenv("WEBKIT_DISABLE_DMABUF_RENDERER"); got != "1" {
		t.Fatalf("WEBKIT_DISABLE_DMABUF_RENDERER=%q, want 1", got)
	}
	if got := os.Getenv("LIBGL_ALWAYS_SOFTWARE"); got != "1" {
		t.Fatalf("LIBGL_ALWAYS_SOFTWARE=%q, want 1", got)
	}
	if got := os.Getenv("WEBKIT_SKIA_ENABLE_CPU_RENDERING"); got != "1" {
		t.Fatalf("WEBKIT_SKIA_ENABLE_CPU_RENDERING=%q, want 1", got)
	}
	if _, ok := os.LookupEnv("WEBKIT_FORCE_COMPOSITING_MODE"); ok {
		t.Fatal("WEBKIT_FORCE_COMPOSITING_MODE was not removed")
	}
	if _, ok := os.LookupEnv("WEBKIT_FORCE_DMABUF_RENDERER"); ok {
		t.Fatal("WEBKIT_FORCE_DMABUF_RENDERER was not removed")
	}

	if _, nvidiaErr := os.Stat("/proc/driver/nvidia/version"); nvidiaErr == nil {
		if _, mesaErr := os.Stat(mesaEGLVendorFile); mesaErr == nil {
			if got := os.Getenv("__EGL_VENDOR_LIBRARY_FILENAMES"); got != mesaEGLVendorFile {
				t.Fatalf("__EGL_VENDOR_LIBRARY_FILENAMES=%q, want %q", got, mesaEGLVendorFile)
			}
			if got := os.Getenv("MESA_LOADER_DRIVER_OVERRIDE"); got != "llvmpipe" {
				t.Fatalf("MESA_LOADER_DRIVER_OVERRIDE=%q, want llvmpipe", got)
			}
		}
	}
}

func TestConfigureLinuxWebKitCompatibilityHonoursNvidiaEGLEscapeHatch(t *testing.T) {
	if bridge.Env.OS != "linux" {
		t.Skip("Linux-only compatibility policy")
	}

	t.Setenv("PRIVATEDEPLOY_ALLOW_NVIDIA_EGL", "1")
	t.Setenv("__EGL_VENDOR_LIBRARY_FILENAMES", "diagnostic-vendor")
	t.Setenv("MESA_LOADER_DRIVER_OVERRIDE", "diagnostic-driver")

	configureLinuxWebKitCompatibility()

	if got := os.Getenv("__EGL_VENDOR_LIBRARY_FILENAMES"); got != "diagnostic-vendor" {
		t.Fatalf("escape hatch changed EGL vendor to %q", got)
	}
	if got := os.Getenv("MESA_LOADER_DRIVER_OVERRIDE"); got != "diagnostic-driver" {
		t.Fatalf("escape hatch changed Mesa driver to %q", got)
	}
	if got := os.Getenv("WEBKIT_DISABLE_COMPOSITING_MODE"); got != "1" {
		t.Fatalf("baseline compositing policy=%q, want 1", got)
	}
}

func TestTerminationSignalsAreConfigured(t *testing.T) {
	if len(terminationSignals()) == 0 {
		t.Fatal("no termination signals configured")
	}
}
