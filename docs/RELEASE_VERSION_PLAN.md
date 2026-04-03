# Release Version Plan

## Current State

The repository has three formal tags:

- `v1.9.9`
- `v1.10.0`
- `v1.10.1`

Current version metadata is now driven from the repo root:

- Shared semantic version: [VERSION](/mnt/data/PrivateDeploy/VERSION) -> `2.0.0`
- Mobile build number: [MOBILE_BUILD_NUMBER](/mnt/data/PrivateDeploy/MOBILE_BUILD_NUMBER) -> `12`
- Desktop app metadata: [wails.json](/mnt/data/PrivateDeploy/wails.json)
- Frontend package metadata: [frontend/package.json](/mnt/data/PrivateDeploy/frontend/package.json)
- Mobile app metadata: [mobile/pubspec.yaml](/mnt/data/PrivateDeploy/mobile/pubspec.yaml)

Single-source version files now exist at the repo root:

- [VERSION](/mnt/data/PrivateDeploy/VERSION)
- [MOBILE_BUILD_NUMBER](/mnt/data/PrivateDeploy/MOBILE_BUILD_NUMBER)

Use [sync_versions.sh](/mnt/data/PrivateDeploy/scripts/sync_versions.sh) to update platform metadata from those files, and [check_versions.sh](/mnt/data/PrivateDeploy/scripts/check_versions.sh) to verify consistency locally or in CI.

At the same time, `main` has moved far beyond `v1.10.1`:

- Desktop cloud/provider architecture was expanded substantially
- A standalone API module was added
- A full mobile VPN application was added and repeatedly hardened
- CI/CD and packaging workflows were broadened across desktop and mobile

Treating current `main` as another `1.10.1` build is no longer coherent.

## Selected Release

Chosen version: `v2.0.0`

Reason:

- `v1.10.1` is the last coherent formal stable baseline.
- Current `main` is not a small incremental patch or minor update.
- The repository now represents a broader product boundary than the `1.10.x` line.

## Recommendation

### Preferred

Release current `main` as `v2.0.0`.

Use `v2.0.0` if the release message is:

- PrivateDeploy is now a multi-surface product
- Desktop, mobile, and API are all first-class deliverables
- The release should communicate a clear product-generation boundary

This is the recommendation for the current repository shape.

### Conservative Alternative

Release current `main` as `v1.11.0`.

Use `v1.11.0` only if:

- Desktop remains the only officially supported release artifact
- Mobile and API are still considered preview / internal / companion deliverables
- You want to minimize external perception of breaking change

## Suggested Version Matrix

If you choose the recommended path:

- Git tag: `v2.0.0`
- Desktop metadata: `2.0.0`
- Frontend package metadata: `2.0.0`
- Mobile metadata: `2.0.0+1` or `2.0.0+12`

If you choose the conservative path:

- Git tag: `v1.11.0`
- Desktop metadata: `1.11.0`
- Frontend package metadata: `1.11.0`
- Mobile metadata: `1.11.0+1` or `1.11.0+12`

The mobile build number choice depends on whether you want to reset platform build counters for the first formal mobile release. Keeping the next monotonic build number is safer for store distribution.

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

1. Fix the current Flutter analyze warning in [apikey_test.dart](/mnt/data/PrivateDeploy/mobile/integration_test/apikey_test.dart#L46).
2. Run `go test /mnt/data/PrivateDeploy/...`.
3. Run `pnpm exec vue-tsc --noEmit` in `frontend/`.
4. Run `pnpm vitest run` in `frontend/`.
5. Run `flutter analyze` in `mobile/`.
6. Run `flutter test --reporter compact` in `mobile/`.
7. Confirm desktop and mobile release artifacts are built from the same intended commit.

## Tagging Guidance

Suggested flow:

1. Finalize and commit unreleased product work.
2. Update version metadata in desktop and mobile files.
3. Review and trim the `Unreleased` section in [CHANGELOG.md](/mnt/data/PrivateDeploy/CHANGELOG.md) into the final tagged section.
4. Create the annotated tag.
5. Build desktop and mobile artifacts from that exact tag.

## Decision Summary

Recommended decision: `v2.0.0`
