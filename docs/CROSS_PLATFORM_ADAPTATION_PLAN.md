# Cross-Platform Adaptation Plan

## Goal

Make PrivateDeploy stable and behaviorally consistent across Linux, Windows, and macOS for:

- Desktop startup
- Native webview rendering
- System proxy management
- Tray integration
- Startup-on-boot
- Cloud deployment UI flows
- Kernel start/stop and profile apply flows

## Status

Already fixed:

- Linux blank window caused by unsafe `webviewGpuPolicy` defaults and migration

Still needs platform hardening:

- Native control interaction consistency
- Platform-specific system integration behavior
- Real desktop E2E regression on all target platforms

## Workstreams

### 1. Desktop Runtime Safety

Purpose:
Prevent platform-specific startup and rendering failures before UI logic even runs.

Files:

- `main.go`
- `bridge/bridge.go`
- `bridge/types.go`
- `frontend/src/stores/appSettings.ts`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`

Tasks:

1. Define platform-safe defaults for webview/GPU policy by OS.
2. Add startup migration rules for deprecated or unsafe values.
3. Expand startup diagnostics to log:
   - OS
   - display session type
   - webview GPU policy
   - app version
4. Add platform-specific startup preflight checks:
   - Linux: X11/Wayland reachability
   - Windows: WebView2 runtime availability
   - macOS: relevant permission and runtime checks

Acceptance:

- App starts without white/blank window on supported desktop environments.
- Invalid old settings auto-migrate without user intervention.
- Startup failures produce actionable errors instead of silent broken windows.

### 2. System Proxy Lifecycle

Purpose:
Make proxy behavior safe, reversible, and platform-correct.

Files:

- `frontend/src/stores/env.ts`
- `frontend/src/stores/kernelApi.ts`
- `frontend/src/utils/helper.ts`
- `frontend/src/App.vue`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- platform-specific bridge/process helpers under `bridge/`

Tasks:

1. Split proxy operations into a platform capability layer instead of implicit shared logic.
2. Guarantee backup/restore semantics for:
   - first enable
   - normal stop
   - crash recovery
   - app upgrade/restart
3. Normalize app-managed proxy detection across HTTP/SOCKS variants.
4. Add explicit proxy-state diagnostics to logs and UI.
5. Add regression tests for:
   - existing system proxy present
   - app sets proxy
   - app exits unexpectedly
   - proxy is restored

Acceptance:

- Enabling proxy never destroys an existing user proxy without backup.
- Stopping the kernel or app restores previous proxy state reliably.
- Crash recovery does not leave a stale app-managed proxy behind.

### 3. Tray And Native Shell Integration

Purpose:
Keep tray, menus, and native shell features consistent across OSes.

Files:

- `bridge/tray.go`
- `frontend/src/utils/tray.ts`
- `frontend/src/utils/command.ts`
- `frontend/src/components/TitleBar.vue`

Tasks:

1. Audit tray support differences by platform:
   - icon rendering
   - menu click behavior
   - window show/hide
2. Define graceful fallback when tray is unavailable or unstable.
3. Verify menu parity for:
   - kernel actions
   - proxy actions
   - profile groups
   - restart/exit
4. Add platform-specific smoke tests for tray-triggered actions.

Acceptance:

- Tray works or degrades cleanly on each target OS.
- Tray actions match in-app actions and do not drift functionally.

### 4. Startup-On-Boot And Permissions

Purpose:
Make startup behavior explicit and platform-correct.

Files:

- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- `frontend/src/utils/others.ts`
- `frontend/src/utils/helper.ts`
- `main.go`
- platform-specific startup helpers under `bridge/`

Tasks:

1. Replace Windows-centric startup assumptions with per-platform implementations.
2. Support and validate:
   - Windows scheduled task / startup entry
   - Linux desktop autostart
   - macOS login item / launch agent
3. Separate "needs admin" from "needs restart" from "supported on this OS".
4. Expose unsupported features clearly in UI instead of hiding ambiguous behavior.

Acceptance:

- Each OS either supports startup cleanly or clearly reports unsupported state.
- Settings page reflects actual platform capability, not generic toggles.

### 5. Native UI Control Consistency

Purpose:
Reduce OS-specific interaction drift in real desktop windows.

Files:

- `frontend/src/views/CloudView/index.vue`
- `frontend/src/components/Dropdown/index.vue`
- `frontend/src/components/Input/index.vue`
- `frontend/src/components/Menu/index.vue`
- `frontend/src/components/Modal/index.vue`
- `frontend/src/components/Tips/index.vue`

Tasks:

1. Audit dropdown, modal, input, and keyboard-focus behavior in desktop runtime.
2. Fix native interaction edge cases:
   - dropdown open/close behavior
   - keyboard selection
   - focus loss
   - overlay stacking
3. Verify HiDPI pointer hit targets and coordinate correctness.
4. Add native desktop UI smoke flows for:
   - switching cloud provider
   - opening modal
   - saving config
   - applying node

Acceptance:

- Critical controls behave consistently on Linux, Windows, and macOS.
- Provider switch and node apply can be completed via mouse and keyboard.

### 6. Cloud Workflow Regression

Purpose:
Ensure the main deployment workflow behaves the same across desktop and browser-backed test harnesses.

Files:

- `frontend/src/views/CloudView/index.vue`
- `frontend/src/stores/cloud.ts`
- `bridge/cloud_bridge.go`
- `e2e/run_cloud_ui_e2e.py`
- `tmp/pdcloudctl/main.go`

Tasks:

1. Keep browser-backed cloud regression as a fast functional baseline.
2. Add native desktop cloud smoke flow covering:
   - open Deploy page
   - switch provider
   - refresh nodes
   - apply node to profile
3. Add assertions for protocol-selection behavior:
   - degraded protocols excluded from managed subscription
   - per-node best-protocol auto groups present
4. Validate provider switching preserves provider-specific configs correctly.

Acceptance:

- Cloud page works in both mocked browser regression and native desktop regression.
- DO nodes remain eligible for `Hysteria2` when healthy.
- Vultr nodes with degraded `Hysteria2` are excluded automatically.

### 7. Platform Capability Layer

Purpose:
Stop scattering OS checks through UI and stores.

Files:

- `frontend/src/stores/env.ts`
- `frontend/src/stores/appSettings.ts`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- `bridge/types.go`
- `bridge/bridge.go`

Tasks:

1. Introduce a unified capability model returned from bridge/env:
   - traySupported
   - systemProxySupported
   - startupSupported
   - adminElevationSupported
   - configurableWebviewGpuPolicy
2. Drive UI visibility and copy from capabilities instead of hard-coded OS branches.
3. Centralize platform feature policy in one place.

Acceptance:

- Settings UI reflects real capabilities, not guessed platform assumptions.
- New platform-specific branches are added in one layer instead of many.

### 8. Test Matrix

Target environments:

1. Linux X11
2. Linux Wayland
3. Windows 10
4. Windows 11
5. macOS Intel
6. macOS Apple Silicon

Per-platform mandatory cases:

1. App launches without blank window.
2. Settings changes persist after restart.
3. Deploy page opens.
4. Cloud provider switches correctly.
5. Node list refresh works.
6. Node apply updates current profile.
7. Kernel starts and stops.
8. System proxy sets, clears, and restores.
9. App exits without leaving stale state.

## Delivery Order

### Phase 1

- Desktop runtime safety
- Platform capability layer
- System proxy lifecycle hardening

### Phase 2

- Tray and startup-on-boot integration
- Native UI control consistency

### Phase 3

- Native desktop cloud regression
- Full cross-platform test matrix

## Current Priority

Implement next in this order:

1. Platform capability layer
2. System proxy lifecycle regression coverage
3. Native CloudView control consistency, especially provider dropdown interaction
