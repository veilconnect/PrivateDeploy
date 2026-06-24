# Changelog

**English** | [中文](CHANGELOG.zh-CN.md)

This changelog backfills release notes from the git history and records the next unreleased line of work.

The project has gone through two distinct product phases:

- `GUI.for.SingBox`: a desktop sing-box GUI client
- `PrivateDeploy`: a desktop + cloud automation product, now with a mobile companion and standalone API module on `main`

## [Unreleased]

- No unreleased notes yet.

## [2.0.10] - 2026-06-24

### Tests
- **Secure storage fail-closed coverage**: added a regression test for the
  `getSecureString` legacy-migration path when the keystore is unavailable. It
  locks in the intended behavior — return the already-stored legacy secret and
  retain the plaintext mirror for a later retry, rather than locking the user
  out of their own credential. The fail-closed contract governs *writes* of new
  plaintext, not destruction of already-persisted data; this test prevents a
  future "return null" regression from breaking existing users.

## [2.0.9] - 2026-06-23

### Fixed
- **CDN Worker error 1101 (root cause of CDN bypass failing)**: the deployed Worker's
  `compatibility_date` was pinned at 2024-09-23. After a Cloudflare runtime change in early
  2026, `import { connect } from 'cloudflare:sockets'` failed to load under that stale date,
  so every Worker returned CF 1101 — the entire CDN relay path was dead, and nodes whose
  direct IP a carrier blocks on cellular could no longer be reached via CDN. Bumped both the
  mobile `_kCompatDate` and desktop `bridge/cdn` `workerCompatDate` to 2026-06-01.

### Added
- **Region reachability in the deploy dialog**: when creating a node, the region dropdown now
  probes each Vultr region's latency/reachability from the device's current network, sorts by
  latency, auto-selects the fastest reachable region, flags unreachable ones, and shows a regional reachability
  risk indicator (🟢🟡🟠🔴). Results are persisted so a cold open shows them immediately.
  The desktop also persists its region-latency results.
- **CDN redeploy & self-heal**: deployed nodes get an in-place "Redeploy" button (overwrites
  the Worker, no more delete-then-deploy); the cellular auto-deploy now re-deploys when it
  detects a broken Worker; added a deployment-health verdict.

## [2.0.0] - 2026-04-03

### Added

- Standalone REST API module for cloud, profile, subscription, system, VPN, and websocket workflows.
- Cross-platform mobile application with Android/iOS VPN integration, cloud node management, diagnostics, backup/restore, and routing controls.
- Mobile split-routing controls with built-in CN rule sets, custom rules, and app-based direct/proxy routing on Android.
- Mobile VPN diagnostics with recent routing decisions and egress IP probing.
- Real-download cloud benchmark flow for mobile, alongside lightweight quick-test latency selection.
- Expanded cloud provider stack and supporting infrastructure, including provider catalog modules, cloud secret storage, health monitoring, recommendation helpers, and filesystem services.
- Additional CI/CD workflows for mobile build, test, and release automation.

### Changed

- Desktop cloud management was refactored into a more modular store architecture with clearer history, instance sync, backup, smart routing, and presentation layers.
- Desktop startup, system proxy, runtime seeding, and recovery flows were hardened across Linux, Windows, and release packaging.
- Mobile workspace, settings, dialogs, sections, and action flows were split into smaller modules with broader unit and integration coverage.
- Mobile node selection now prefers recent benchmark winners and can reuse them from the top-level `Connect` action.

### Fixed

- Multiple cloud deployment, sync, and startup race conditions across desktop and mobile.
- Windows runtime seeding and readiness mismatches for bundled core binaries.
- Mobile VPN conflict handling, Android DNS / Private DNS compatibility, diagnostics responsiveness, connection-state UX, and subscription import / backup restore edge cases.
- Cloud benchmark accuracy and per-node / per-protocol selection behavior.
- Security and robustness issues around credentials, startup recovery, runtime environment handling, and deployment hardening.

## [1.10.1] - 2025-11-04

First formal `PrivateDeploy` release line.

### Added

- Cloud provider infrastructure and the first full cloud management surface in the desktop app.
- Vultr-centered hardened multi-protocol deployment workflow for Shadowsocks, Hysteria2, VLESS-Reality, and Trojan.
- Deployment progress timeline, cloud node auto-apply, auto-start improvements, and better cloud UX around provider/plan/region selection.
- GitHub Actions updates for repository rename and multi-platform build automation.

### Changed

- Project name, repository references, and branding were migrated from `VeilDeploy` / `GUI.for.SingBox` to `PrivateDeploy`.
- README and user-facing docs were rewritten around cloud-backed node deployment instead of a generic local GUI story.

### Fixed

- Startup ordering so cloud nodes are applied before kernel launch.
- Startup hangs and stale provider state when switching plans / regions.
- Retry logic for nodes that receive IPs later in the provisioning lifecycle.
- Several UX issues around cloud provider selection and deployment display.

## [1.10.0] - 2025-09-22

Last major release in the pre-PrivateDeploy desktop line.

### Added

- Dynamic i18n loading support.
- More granular kernel startup / stop state management.
- Accessibility and usability improvements for switches, dropdowns, selects, and controller settings.
- Profile routing controls including `route_exclude_address` and default ICMP direct rule handling.
- Optional debug no-animation setting.

### Changed

- Scheduled task handling moved away from the previous Go-based path.
- Desktop UI primitives, selection controls, and startup lifecycle logic were refactored for better stability.
- Release build / artifact flow was streamlined.

### Fixed

- Core stop state handling and home view rendering.
- Memory pressure from fetching excessive release entries in core-branch logic.
- Profile-switch startup order and stale kernel log behavior.
- Recursive table render issues and several UI interaction regressions.

## [1.9.9] - 2025-08-27

Late maintenance release in the original `GUI.for.SingBox` line.

### Changed

- Small bridge and frontend environment adjustments before the larger `v1.10.x` desktop refactor line.

### Notes

- This version still belongs to the old generic sing-box desktop GUI era and does not reflect the later `PrivateDeploy` cloud automation direction.
