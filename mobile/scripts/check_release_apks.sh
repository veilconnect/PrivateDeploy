#!/usr/bin/env bash
#
# Verify that the release APKs under build/app/outputs/flutter-apk/ match
# the current pubspec.yaml version. Use as a fast "is the build up to date"
# check (git pre-push hook, CI gate) without actually rebuilding.
#
# Exits 0 if every release APK matches pubspec, 1 if any is stale or missing.
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MOBILE_DIR"

PUBSPEC_VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}')"
PUBSPEC_NAME="${PUBSPEC_VERSION%+*}"
PUBSPEC_CODE="${PUBSPEC_VERSION#*+}"

APK_DIR="$MOBILE_DIR/build/app/outputs/flutter-apk"
if [ ! -d "$APK_DIR" ]; then
  echo "⚠  $APK_DIR does not exist; no release APKs to verify."
  exit 0
fi

ANDROID_SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
AAPT="$(ls -1d "$ANDROID_SDK"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$AAPT" ]; then
  echo "⚠  aapt not found under $ANDROID_SDK/build-tools/; skipping version check."
  exit 0
fi

shopt -s nullglob
apks=("$APK_DIR"/*-release.apk)
if [ ${#apks[@]} -eq 0 ]; then
  echo "⚠  no release APKs found in $APK_DIR; skipping."
  exit 0
fi

FAIL=0
for apk in "${apks[@]}"; do
  # grep for the 'package:' line directly so SIGPIPE from 'head -1' under
  # set -o pipefail doesn't kill the script.
  info="$("$AAPT" dump badging "$apk" 2>/dev/null | grep '^package:' || true)"
  version_name="$(echo "$info" | grep -oE "versionName='[^']*'" | head -1 | sed "s/versionName='//;s/'//")"
  version_code="$(echo "$info" | grep -oE "versionCode='[^']*'" | head -1 | sed "s/versionCode='//;s/'//")"
  if [ "$version_name" != "$PUBSPEC_NAME" ] || [[ "$version_code" != *"$PUBSPEC_CODE" ]]; then
    echo "  ✗ $(basename "$apk") is $version_name ($version_code), expected $PUBSPEC_NAME (*$PUBSPEC_CODE)"
    FAIL=1
  fi
done

if [ "$FAIL" = 1 ]; then
  cat <<EOF >&2

error: stale release APKs detected. Rebuild with:
  mobile/scripts/build_release.sh

This check exists because 2.0.0 was almost shipped with 1.10.1 release APKs
on 2026-04-07 — pubspec was bumped but nobody rebuilt the release artifacts.
EOF
  exit 1
fi
