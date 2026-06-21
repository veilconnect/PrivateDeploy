#!/usr/bin/env bash
#
# Build all Android release APKs (universal + split-per-ABI) and verify
# that each artifact's embedded version matches pubspec.yaml. Intended to
# be run every time the pubspec version bumps, and by CI on tag pushes.
#
# Regression it prevents: 2.0.0 release test drift on 2026-04-07 where
# pubspec was bumped to 2.0.0+12 but only the debug APK was rebuilt,
# leaving stale 1.10.1+11 release APKs in build/app/outputs/flutter-apk/.
# Users running "the 2.0.0 release" were actually running 1.10.1.
#
# Usage: mobile/scripts/build_release.sh [--skip-split]
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MOBILE_DIR"

FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"
if [ ! -x "$FLUTTER" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER="$(command -v flutter)"
  else
    echo "error: flutter not found (tried $FLUTTER and PATH)" >&2
    exit 1
  fi
fi

SKIP_SPLIT=0
for arg in "$@"; do
  case "$arg" in
    --skip-split) SKIP_SPLIT=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Extract version from pubspec.yaml. Format is "version: X.Y.Z+BUILD".
PUBSPEC_VERSION_LINE="$(grep -E '^version:' pubspec.yaml | head -1)"
if [ -z "$PUBSPEC_VERSION_LINE" ]; then
  echo "error: no 'version:' line in pubspec.yaml" >&2
  exit 1
fi
PUBSPEC_VERSION="$(echo "$PUBSPEC_VERSION_LINE" | awk '{print $2}')"
PUBSPEC_NAME="${PUBSPEC_VERSION%+*}"     # X.Y.Z
PUBSPEC_CODE="${PUBSPEC_VERSION#*+}"     # BUILD
if [ "$PUBSPEC_NAME" = "$PUBSPEC_VERSION" ]; then
  echo "error: pubspec version '$PUBSPEC_VERSION' is missing the +BUILD suffix" >&2
  exit 1
fi

echo "→ Building release APKs for $PUBSPEC_VERSION"

"$FLUTTER" build apk --release

if [ "$SKIP_SPLIT" = 0 ]; then
  "$FLUTTER" build apk --release \
    --target-platform android-arm,android-arm64,android-x64 \
    --split-per-abi
fi

# Verify every built release APK reports the expected version. We parse aapt
# (from the newest installed build-tools) so the check matches what the OS
# actually reports at install time.
APK_DIR="$MOBILE_DIR/build/app/outputs/flutter-apk"
ANDROID_SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
AAPT="$(ls -1d "$ANDROID_SDK"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$AAPT" ] || [ ! -x "$AAPT" ]; then
  echo "error: could not find aapt under $ANDROID_SDK/build-tools/*/aapt" >&2
  exit 1
fi

FAIL=0
shopt -s nullglob
for apk in "$APK_DIR"/*-release.apk; do
  info="$("$AAPT" dump badging "$apk" 2>/dev/null | grep '^package:' || true)"
  version_name="$(echo "$info" | grep -oE "versionName='[^']*'" | head -1 | sed "s/versionName='//;s/'//")"
  version_code="$(echo "$info" | grep -oE "versionCode='[^']*'" | head -1 | sed "s/versionCode='//;s/'//")"
  short="$(basename "$apk")"
  if [ "$version_name" != "$PUBSPEC_NAME" ]; then
    echo "  ✗ $short versionName='$version_name' (expected $PUBSPEC_NAME)"
    FAIL=1
    continue
  fi
  # Split APKs carry an ABI multiplier in the HIGH digits of the versionCode:
  # Flutter computes (abiMultiplier * 1000 + pubspec build), e.g. for build
  # 2070 -> 3070 (armeabi-v7a), 4070 (arm64-v8a), 6070 (x86_64); the universal
  # APK uses the build as-is. So the difference from the pubspec build must be
  # a non-negative multiple of 1000. (The old "ends in $PUBSPEC_CODE" test
  # silently broke once the build number itself reached >=1000 — 4070 does not
  # end in 2070.)
  if ! [[ "$version_code" =~ ^[0-9]+$ ]] ||
      (( version_code < PUBSPEC_CODE )) ||
      (( (version_code - PUBSPEC_CODE) % 1000 != 0 )); then
    echo "  ✗ $short versionCode='$version_code' (expected $PUBSPEC_CODE + N×1000)"
    FAIL=1
    continue
  fi
  echo "  ✓ $short  $version_name ($version_code)"
done

if [ "$FAIL" = 1 ]; then
  echo "error: one or more APKs do not match pubspec version" >&2
  exit 1
fi

echo "✓ all release APKs match pubspec $PUBSPEC_VERSION"

# Always emit a version-stamped copy of the universal release APK so the
# artifact name carries X.Y.Z+BUILD (e.g. PrivateDeploy-2.0.2+2070.apk).
# Flutter writes the universal build to a fixed app-release.apk name, which
# is easy to confuse across version bumps; the stamped copy is the one to
# hand off / archive. Verified above, so we only ever stamp a matching APK.
UNIVERSAL_APK="$APK_DIR/app-release.apk"
if [ -f "$UNIVERSAL_APK" ]; then
  cp -f "$UNIVERSAL_APK" "$APK_DIR/PrivateDeploy-$PUBSPEC_VERSION.apk"
  echo "✓ stamped: PrivateDeploy-$PUBSPEC_VERSION.apk (universal, all ABIs)"
fi
# Also stamp the lean arm64-only split when present — it's ~1/3 the size of the
# universal APK (no armv7/x86_64 native libs) and is the right sideload artifact
# for modern phones.
ARM64_APK="$APK_DIR/app-arm64-v8a-release.apk"
if [ -f "$ARM64_APK" ]; then
  cp -f "$ARM64_APK" "$APK_DIR/PrivateDeploy-$PUBSPEC_VERSION-arm64.apk"
  echo "✓ stamped: PrivateDeploy-$PUBSPEC_VERSION-arm64.apk (arm64-v8a only, smaller)"
fi
