#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read_trimmed() {
  tr -d '[:space:]' < "$1"
}

extract_json_version() {
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

extract_json_product_version() {
  sed -n 's/^[[:space:]]*"productVersion":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

extract_pubspec_version() {
  sed -n 's/^version:[[:space:]]*\(.*\)$/\1/p' "$1" | head -n 1 | tr -d '[:space:]'
}

# bridge.go declares: var AppVersion = "dev"
# The default MUST stay "dev" so that unbranded local builds are obvious
# and so the only way to ship a real version is via -ldflags. A previous
# regression saw this hardcoded as "v1.10.1" and the API kept reporting
# 1.10.1 long after the rest of the tree moved to 2.0.0+12.
extract_bridge_app_version_default() {
  sed -n 's/^var AppVersion = "\([^"]*\)".*/\1/p' "$1" | head -n 1
}

ROOT_VERSION="$(read_trimmed "$ROOT_DIR/VERSION")"
MOBILE_BUILD_NUMBER="$(read_trimmed "$ROOT_DIR/MOBILE_BUILD_NUMBER")"
EXPECTED_MOBILE_VERSION="${ROOT_VERSION}+${MOBILE_BUILD_NUMBER}"

WAILS_VERSION="$(extract_json_version "$ROOT_DIR/wails.json")"
WAILS_PRODUCT_VERSION="$(extract_json_product_version "$ROOT_DIR/wails.json")"
FRONTEND_VERSION="$(extract_json_version "$ROOT_DIR/frontend/package.json")"
MOBILE_VERSION="$(extract_pubspec_version "$ROOT_DIR/mobile/pubspec.yaml")"
BRIDGE_APP_VERSION="$(extract_bridge_app_version_default "$ROOT_DIR/bridge/bridge.go")"

fail() {
  echo "Version consistency check failed: $1" >&2
  echo "Expected desktop/frontend version: $ROOT_VERSION" >&2
  echo "Expected mobile version: $EXPECTED_MOBILE_VERSION" >&2
  echo "Found wails.json version: $WAILS_VERSION" >&2
  echo "Found wails.json info.productVersion: $WAILS_PRODUCT_VERSION" >&2
  echo "Found frontend/package.json version: $FRONTEND_VERSION" >&2
  echo "Found mobile/pubspec.yaml version: $MOBILE_VERSION" >&2
  echo "Found bridge/bridge.go AppVersion default: $BRIDGE_APP_VERSION" >&2
  exit 1
}

[[ -n "$ROOT_VERSION" ]] || fail "VERSION is empty"
[[ -n "$MOBILE_BUILD_NUMBER" ]] || fail "MOBILE_BUILD_NUMBER is empty"
[[ "$WAILS_VERSION" == "$ROOT_VERSION" ]] || fail "wails.json is out of sync"
[[ "$WAILS_PRODUCT_VERSION" == "$ROOT_VERSION" ]] || fail "wails.json info.productVersion is out of sync"
[[ "$FRONTEND_VERSION" == "$ROOT_VERSION" ]] || fail "frontend/package.json is out of sync"
[[ "$MOBILE_VERSION" == "$EXPECTED_MOBILE_VERSION" ]] || fail "mobile/pubspec.yaml is out of sync"
[[ "$BRIDGE_APP_VERSION" == "dev" ]] || fail "bridge/bridge.go AppVersion default must stay \"dev\" — release versions are injected via ldflags (-X privatedeploy/bridge.AppVersion=...)"

echo "Version consistency OK: desktop/frontend=$ROOT_VERSION mobile=$EXPECTED_MOBILE_VERSION bridge.AppVersion=dev (ldflags-injectable)"
