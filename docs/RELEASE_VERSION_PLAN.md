# Release Version Plan

## Current State

The repository has formal tags across the `1.x` and `2.x` lines:

- `v1.9.9`
- `v1.10.0`
- `v1.10.1`
- `v2.0.2` through `v2.0.12` with some skipped patch numbers

Current version metadata is driven from the repo root:

- Shared semantic version: [VERSION](/mnt/data/PrivateDeploy/VERSION) -> `2.0.12`
- Mobile build number: [MOBILE_BUILD_NUMBER](/mnt/data/PrivateDeploy/MOBILE_BUILD_NUMBER) -> `2081`
- Desktop app metadata: [wails.json](/mnt/data/PrivateDeploy/wails.json)
- Frontend package metadata: [frontend/package.json](/mnt/data/PrivateDeploy/frontend/package.json)
- Mobile app metadata: [mobile/pubspec.yaml](/mnt/data/PrivateDeploy/mobile/pubspec.yaml)

Single-source version files now exist at the repo root:

- [VERSION](/mnt/data/PrivateDeploy/VERSION)
- [MOBILE_BUILD_NUMBER](/mnt/data/PrivateDeploy/MOBILE_BUILD_NUMBER)

Use [sync_versions.sh](/mnt/data/PrivateDeploy/scripts/sync_versions.sh) to update platform metadata from those files, and [check_versions.sh](/mnt/data/PrivateDeploy/scripts/check_versions.sh) to verify consistency locally or in CI.

The `2.x` line is now the right product line for the repository shape:

- Desktop cloud/provider architecture was expanded substantially
- A standalone API module was added
- A full mobile VPN application was added and repeatedly hardened
- CI/CD and packaging workflows were broadened across desktop and mobile

Treating current `main` as a `1.x` build is no longer coherent.

## Selected Release

Chosen release line: `v2.x`

Current metadata version: `2.0.12`

Recommended next public test release from a modified `main`: `v2.0.13-beta.1` or `v2.0.13-preview.1`

Reason:

- `v1.10.1` is the last coherent formal stable baseline.
- Current `main` has already crossed into a broader `2.x` product boundary.
- The repository now represents a broader product boundary than the `1.10.x` line.
- The `v2.0.12` tag already exists, so any new release that includes post-tag changes must use a new version.

## Recommendation

### Preferred Near-Term Release

Release the next build as a `Beta` / `Preview` build, not as a fully stable release, unless every item in [GO-NO-GO-CHECKLIST.md](/mnt/data/PrivateDeploy/docs/GO-NO-GO-CHECKLIST.md) passes.

Use `v2.0.13-beta.1` or `v2.0.13-preview.1` if the release message is:

- PrivateDeploy is now a multi-surface product
- Desktop, mobile, and API are all first-class deliverables
- Desktop and Android are ready for broader testing
- iOS and real cloud-provider coverage may still be limited by the stated known issues

This is the recommendation for the current repository state.

### Stable Release Condition

Use a stable `v2.0.13` release only if:

- Desktop packages are installed and launched on Windows, macOS, and Linux.
- Android install, VPN permission, connect, disconnect, and uninstall flows pass on a real device.
- iOS is either fully validated or explicitly excluded from the stable support matrix.
- At least the cloud providers named in the release notes pass create, deploy, connect, and delete smoke tests.
- Secret scanning confirms that no API key, private key, token, node password, subscription URL, or real credential appears in source, logs, screenshots, or release artifacts.
- Release notes list known issues and verified platforms.

## Suggested Version Matrix

If you choose the recommended Beta / Preview path:

- Git tag: `v2.0.13-beta.1` or `v2.0.13-preview.1`
- Desktop metadata: `2.0.13-beta.1` or `2.0.13-preview.1`
- Frontend package metadata: same as desktop metadata
- Mobile metadata: `2.0.13+2082` or the next monotonic build number accepted by the store/distribution channel

If you choose the stable path after all gates pass:

- Git tag: `v2.0.13`
- Desktop metadata: `2.0.13`
- Frontend package metadata: `2.0.13`
- Mobile metadata: `2.0.13+2082` or the next monotonic build number accepted by the store/distribution channel

Keep the mobile build number monotonic. Do not reset it for patch or preview releases.

## Files To Update Before Tagging

### Desktop

- [VERSION](/mnt/data/PrivateDeploy/VERSION)
- [wails.json](/mnt/data/PrivateDeploy/wails.json)
- [frontend/package.json](/mnt/data/PrivateDeploy/frontend/package.json)

### Mobile

- [MOBILE_BUILD_NUMBER](/mnt/data/PrivateDeploy/MOBILE_BUILD_NUMBER)
- [mobile/pubspec.yaml](/mnt/data/PrivateDeploy/mobile/pubspec.yaml)

### Release Notes

- [CHANGELOG.md](/mnt/data/PrivateDeploy/CHANGELOG.md)

## Release Gate

Before cutting the next tag, complete at least this minimum gate:

1. Run `bash scripts/check_versions.sh`.
2. Run `go test ./...`.
3. Run `cd api && go test ./...`.
4. Run `pnpm exec vue-tsc --build` in `frontend/`.
5. Run `pnpm vitest run` in `frontend/`.
6. Run `pnpm run build` or the equivalent direct `vite build` command in `frontend/`.
7. Run `flutter analyze --no-fatal-infos` in `mobile/`.
8. Run `flutter test --reporter compact` in `mobile/`.
9. Run `python3 e2e/run_cloud_ui_e2e.py`.
10. Confirm desktop and mobile release artifacts are built from the same intended commit.
11. Complete the P0 section in [GO-NO-GO-CHECKLIST.md](/mnt/data/PrivateDeploy/docs/GO-NO-GO-CHECKLIST.md).

## Tagging Guidance

Suggested flow:

1. Finalize and commit unreleased product work.
2. Update version metadata in desktop and mobile files.
3. Review and trim the `Unreleased` section in [CHANGELOG.md](/mnt/data/PrivateDeploy/CHANGELOG.md) into the final tagged section.
4. Create the annotated tag.
5. Build desktop and mobile artifacts from that exact tag.

## Decision Summary

Recommended decision: publish the next build as `v2.0.13-beta.1` / `v2.0.13-preview.1` unless the full GO/NO-GO checklist passes, then publish as `v2.0.13`.
