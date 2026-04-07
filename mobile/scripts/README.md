# mobile/scripts

Build and verification helpers for the Flutter Android client.

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
