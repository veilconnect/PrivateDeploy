#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
MOBILE_BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/MOBILE_BUILD_NUMBER")"
EXPECTED_MOBILE_VERSION="${ROOT_VERSION}+${MOBILE_BUILD_NUMBER}"

perl -0pi -e 's/"version": "[^"]+"/"version": "'"$ROOT_VERSION"'"/' "$ROOT_DIR/wails.json"
perl -0pi -e 's/"productVersion": "[^"]+"/"productVersion": "'"$ROOT_VERSION"'"/' "$ROOT_DIR/wails.json"
perl -0pi -e 's/"version": "[^"]+"/"version": "'"$ROOT_VERSION"'"/' "$ROOT_DIR/frontend/package.json"
perl -0pi -e 's/^version: .*/version: '"$EXPECTED_MOBILE_VERSION"'/m' "$ROOT_DIR/mobile/pubspec.yaml"

bash "$ROOT_DIR/scripts/check_versions.sh"

echo "Synchronized version metadata to $ROOT_VERSION (mobile build $MOBILE_BUILD_NUMBER)."
