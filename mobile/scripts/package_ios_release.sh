#!/usr/bin/env bash
# Verify the signed IPA, embedded extension and provisioning profiles, then
# create a versioned/checksummed release handoff directory.
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$MOBILE_DIR/.." && pwd)"
IPA="${1:-}"
OUTPUT_DIR="${2:-$MOBILE_DIR/build/release-ready/ios}"
ARCHIVE="${3:-}"
if [ "$(uname -s)" != Darwin ]; then
  echo "error: iOS package verification requires macOS" >&2
  exit 1
fi
if [ -z "$IPA" ] || [ ! -s "$IPA" ]; then
  echo "error: path to a non-empty exported IPA is required" >&2
  exit 1
fi
if [ -z "${PRIVATEDEPLOY_IOS_SIGNING_CERT_SHA256:-}" ] || [ -z "${PRIVATEDEPLOY_APPLE_TEAM_ID:-}" ]; then
  echo "error: pinned iOS certificate SHA-256 and Apple team ID are required for artifact verification" >&2
  exit 1
fi
expected_cert="$(printf '%s' "$PRIVATEDEPLOY_IOS_SIGNING_CERT_SHA256" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]')"
if ! [[ "$expected_cert" =~ ^[0-9A-F]{64}$ ]]; then
  echo "error: pinned iOS certificate SHA-256 is malformed" >&2
  exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/privatedeploy-ipa.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$IPA" "$work"
app="$work/Payload/Runner.app"
extension="$app/PlugIns/VPNExtension.appex"

verify_bundle() {
  local bundle="$1" expected_bundle="$2" prefix="$3"
  if [ ! -d "$bundle" ]; then
    echo "error: exported IPA is missing signed bundle $bundle" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=2 "$bundle"

  codesign -d --extract-certificates "$work/$prefix-cert" "$bundle" 2>/dev/null
  if [ ! -s "$work/$prefix-cert0" ]; then
    echo "error: could not extract signing certificate from $expected_bundle" >&2
    exit 1
  fi
  actual_cert="$(openssl x509 -inform DER -in "$work/$prefix-cert0" -outform DER | shasum -a 256 | awk '{print toupper($1)}')"
  if [ "$actual_cert" != "$expected_cert" ]; then
    echo "error: $expected_bundle is not signed by the pinned Apple Distribution certificate" >&2
    exit 1
  fi

  codesign -d --entitlements :- "$bundle" >"$work/$prefix-entitlements.plist" 2>/dev/null
  plutil -lint "$work/$prefix-entitlements.plist" >/dev/null
  entitlements="$(/usr/libexec/PlistBuddy -c 'Print' "$work/$prefix-entitlements.plist")"
  for required_value in group.com.privatedeploy.mobile packet-tunnel-provider; do
    if ! printf '%s\n' "$entitlements" | grep -Fq "$required_value"; then
      echo "error: signed $expected_bundle lacks entitlement '$required_value'" >&2
      exit 1
    fi
  done
  if [ "$expected_bundle" = com.privatedeploy.mobile ] && \
      ! printf '%s\n' "$entitlements" | grep -Fq app-proxy-provider; then
    echo "error: signed app lacks app-proxy-provider entitlement" >&2
    exit 1
  fi

  if [ ! -s "$bundle/embedded.mobileprovision" ]; then
    echo "error: distribution bundle lacks an embedded provisioning profile: $bundle" >&2
    exit 1
  fi
  security cms -D -i "$bundle/embedded.mobileprovision" >"$work/$prefix-profile.plist"
  embedded_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$work/$prefix-profile.plist")"
  if [ "$embedded_identifier" != "$PRIVATEDEPLOY_APPLE_TEAM_ID.$expected_bundle" ]; then
    echo "error: embedded profile does not match $expected_bundle and configured Apple team" >&2
    exit 1
  fi
}

verify_bundle "$app" com.privatedeploy.mobile app
verify_bundle "$extension" com.privatedeploy.mobile.VPNExtension extension

if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" != com.privatedeploy.mobile ]; then
  echo "error: exported app has an unexpected bundle identifier" >&2
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Info.plist")" != com.privatedeploy.mobile.VPNExtension ]; then
  echo "error: exported VPN extension has an unexpected bundle identifier" >&2
  exit 1
fi

pubspec_version="$(awk '/^version:/{print $2; exit}' "$MOBILE_DIR/pubspec.yaml")"
version_name="${pubspec_version%+*}"
build_number="${pubspec_version#*+}"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" != "$version_name" ] || \
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" != "$build_number" ]; then
  echo "error: exported IPA version does not match mobile/pubspec.yaml" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
ipa_name="PrivateDeploy-ios-${version_name}+${build_number}.ipa"
install -m 0644 "$IPA" "$OUTPUT_DIR/$ipa_name"
checksum_files=("$ipa_name")
if [ -n "$ARCHIVE" ] && [ -d "$ARCHIVE/dSYMs" ]; then
  dsym_name="PrivateDeploy-ios-${version_name}+${build_number}-dSYMs.zip"
  ditto -c -k --sequesterRsrc --keepParent "$ARCHIVE/dSYMs" "$OUTPUT_DIR/$dsym_name"
  checksum_files+=("$dsym_name")
fi
legal_sources=(
  "$ROOT_DIR/LICENSE"
  "$ROOT_DIR/THIRD_PARTY_LICENSES.md"
  "$ROOT_DIR/third_party/THIRD_PARTY_NOTICES.txt"
  "$ROOT_DIR/third_party/sbom.spdx.json"
)
for legal_file in "${legal_sources[@]}"; do
  if [ ! -s "$legal_file" ]; then
    echo "error: required legal/SBOM release file is missing: $legal_file" >&2
    exit 1
  fi
done
license_name='PrivateDeploy-ios-LICENSE.txt'
license_summary_name='PrivateDeploy-ios-THIRD-PARTY-LICENSES.md'
notices_name='PrivateDeploy-ios-THIRD-PARTY-NOTICES.txt'
sbom_name='PrivateDeploy-ios-SBOM.spdx.json'
install -m 0644 "${legal_sources[0]}" "$OUTPUT_DIR/$license_name"
install -m 0644 "${legal_sources[1]}" "$OUTPUT_DIR/$license_summary_name"
install -m 0644 "${legal_sources[2]}" "$OUTPUT_DIR/$notices_name"
install -m 0644 "${legal_sources[3]}" "$OUTPUT_DIR/$sbom_name"
checksum_files+=("$license_name" "$license_summary_name" "$notices_name" "$sbom_name")
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${checksum_files[@]}" >checksums-ios.sha256
  shasum -a 256 -c checksums-ios.sha256
)
echo "Signed iOS release package is ready in $OUTPUT_DIR"
