# mobile/scripts

Build and verification helpers for the Flutter mobile client.

Stable Android/iOS signing, credential names, and the honest limits of CI
validation are documented in [`../STABLE_RELEASE.md`](../STABLE_RELEASE.md).
`check_stable_release_readiness.sh` is the credential-free structural gate;
the `prepare_*_release_signing.sh` and `package_*_release.sh` scripts are used
by the manual stable release workflow and fail closed on missing signatures.

## `build_release.sh`

Builds every Android release APK (universal + split-per-ABI) and verifies
that each artifact's embedded `versionName` / `versionCode` matches the
current `pubspec.yaml` version. Fails loudly if anything drifts.

```bash
mobile/scripts/build_release.sh            # universal + split-per-ABI
mobile/scripts/build_release.sh --skip-split   # universal only (faster)
```

This script exists because on 2026-04-07 we almost shipped 2.0.0 with
stale 1.10.1 release APKs — pubspec had been bumped to 2.0.0+12 but only
the debug APK was rebuilt. Always run this instead of `flutter build apk
--release` directly.

This is a local build helper, not the stable publication path. Stable handoff
artifacts must come from `.github/workflows/mobile-release.yml`, which pins and
verifies their signing certificates.

## `check_release_apks.sh`

Lightweight "are the existing APKs up to date" check. Does **not** rebuild
— just parses `pubspec.yaml` and compares against the APKs under
`build/app/outputs/flutter-apk/`. Intended for pre-push hooks and CI
gating where you want to fail fast without spending 3+ minutes on a full
release build.

```bash
mobile/scripts/check_release_apks.sh
```

## `pre-push.sample`

Git pre-push hook that runs `check_release_apks.sh` automatically. To
enable it in a local clone:

```bash
ln -sf ../../mobile/scripts/pre-push.sample .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

After that, `git push` refuses to proceed if the release APKs don't
match the current pubspec version. Rebuild with `build_release.sh` and
push again.
