#!/usr/bin/env bash
# Install a distribution identity and the app/extension provisioning profiles
# into runner-scoped locations. Must run on macOS. No credential is persisted.
set -euo pipefail

required=(
  PRIVATEDEPLOY_IOS_CERT_P12_BASE64
  PRIVATEDEPLOY_IOS_CERT_PASSWORD
  PRIVATEDEPLOY_IOS_SIGNING_CERT_SHA256
  PRIVATEDEPLOY_IOS_APP_PROFILE_BASE64
  PRIVATEDEPLOY_IOS_EXTENSION_PROFILE_BASE64
  PRIVATEDEPLOY_IOS_EXPORT_OPTIONS_BASE64
  PRIVATEDEPLOY_APPLE_TEAM_ID
  RUNNER_TEMP
  GITHUB_ENV
)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "error: required iOS release secret/environment value '$name' is missing" >&2
    exit 1
  fi
done

if [ "$(uname -s)" != Darwin ]; then
  echo "error: iOS signing preparation requires a macOS runner" >&2
  exit 1
fi

umask 077
cert_path="$RUNNER_TEMP/privatedeploy-distribution.p12"
app_profile="$RUNNER_TEMP/privatedeploy-app.mobileprovision"
extension_profile="$RUNNER_TEMP/privatedeploy-extension.mobileprovision"
export_options="$RUNNER_TEMP/ExportOptions.plist"
keychain="$RUNNER_TEMP/privatedeploy-release.keychain-db"
keychain_password="$(uuidgen)$(uuidgen)"

decode() {
  local value="$1" destination="$2" description="$3"
  if ! printf '%s' "$value" | base64 -D >"$destination" || [ ! -s "$destination" ]; then
    echo "error: $description is not valid non-empty base64 data" >&2
    exit 1
  fi
}
decode "$PRIVATEDEPLOY_IOS_CERT_P12_BASE64" "$cert_path" 'iOS distribution certificate'
decode "$PRIVATEDEPLOY_IOS_APP_PROFILE_BASE64" "$app_profile" 'app provisioning profile'
decode "$PRIVATEDEPLOY_IOS_EXTENSION_PROFILE_BASE64" "$extension_profile" 'extension provisioning profile'
decode "$PRIVATEDEPLOY_IOS_EXPORT_OPTIONS_BASE64" "$export_options" 'ExportOptions.plist'

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$cert_path" -k "$keychain" -P "$PRIVATEDEPLOY_IOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -f pkcs12
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null

identity_report="$(security find-identity -v -p codesigning "$keychain")"
printf '%s\n' "$identity_report"
distribution_identities="$(printf '%s\n' "$identity_report" | grep '"Apple Distribution' || true)"
identity_count="$(printf '%s\n' "$distribution_identities" | grep -c '"Apple Distribution' || true)"
if [ "$identity_count" -ne 1 ]; then
  echo "error: imported p12 must contain exactly one valid Apple Distribution signing identity" >&2
  exit 1
fi
identity_name="$(printf '%s\n' "$distribution_identities" | sed -E 's/.*"([^"]+)".*/\1/')"
expected_cert="$(printf '%s' "$PRIVATEDEPLOY_IOS_SIGNING_CERT_SHA256" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]')"
if ! [[ "$expected_cert" =~ ^[0-9A-F]{64}$ ]]; then
  echo "error: PRIVATEDEPLOY_IOS_SIGNING_CERT_SHA256 must be a 64-character SHA-256 fingerprint" >&2
  exit 1
fi
certificate_pem="$RUNNER_TEMP/privatedeploy-distribution.pem"
certificate_der="$RUNNER_TEMP/privatedeploy-distribution.der"
security find-certificate -c "$identity_name" -p "$keychain" >"$certificate_pem"
openssl x509 -in "$certificate_pem" -outform DER -out "$certificate_der"
if ! openssl x509 -in "$certificate_pem" -checkend 0 -noout; then
  echo "error: Apple Distribution signing certificate is expired" >&2
  exit 1
fi
actual_cert="$(shasum -a 256 "$certificate_der" | awk '{print toupper($1)}')"
if [ "$actual_cert" != "$expected_cert" ]; then
  echo "error: imported p12 does not match the pinned iOS certificate SHA-256" >&2
  exit 1
fi

profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir"

validate_profile() {
  local source="$1" expected_bundle="$2" prefix="$3"
  local decoded="$RUNNER_TEMP/$prefix.plist"
  security cms -D -i "$source" >"$decoded"
  plutil -lint "$decoded" >/dev/null

  local uuid name team application_identifier expiration_epoch now_epoch
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
  name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded")"
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded")"
  application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded")"
  expiration_epoch="$(date -j -f '%a %b %d %T %Z %Y' "$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$decoded")" '+%s')"
  now_epoch="$(date '+%s')"

  if [ "$team" != "$PRIVATEDEPLOY_APPLE_TEAM_ID" ]; then
    echo "error: $prefix profile belongs to team '$team', expected configured team" >&2
    exit 1
  fi
  if [ "$application_identifier" != "$PRIVATEDEPLOY_APPLE_TEAM_ID.$expected_bundle" ]; then
    echo "error: $prefix profile application identifier does not exactly match $expected_bundle" >&2
    exit 1
  fi
  if [ "$expiration_epoch" -le "$now_epoch" ]; then
    echo "error: $prefix provisioning profile is expired" >&2
    exit 1
  fi
  if ! python3 - "$decoded" "$expected_cert" <<'PY'
import hashlib
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    profile = plistlib.load(handle)
expected = sys.argv[2].upper()
actual = {hashlib.sha256(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
if expected not in actual:
    raise SystemExit(1)
PY
  then
    echo "error: $prefix profile does not authorize the pinned Apple Distribution certificate" >&2
    exit 1
  fi
  get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$decoded" 2>/dev/null || printf false)"
  if [ "$get_task_allow" = true ]; then
    echo "error: $prefix profile is a development profile (get-task-allow=true)" >&2
    exit 1
  fi

  # Both native targets request the shared App Group and packet-tunnel
  # capability. The main app additionally declares app-proxy-provider. Check
  # the signed profile entitlements now, rather than waiting for an opaque
  # xcodebuild signing failure.
  entitlements="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements' "$decoded")"
  for required_value in group.com.privatedeploy.mobile packet-tunnel-provider; do
    if ! printf '%s\n' "$entitlements" | grep -Fq "$required_value"; then
      echo "error: $prefix profile lacks required entitlement value '$required_value'" >&2
      exit 1
    fi
  done
  if [ "$expected_bundle" = com.privatedeploy.mobile ] && \
      ! printf '%s\n' "$entitlements" | grep -Fq app-proxy-provider; then
    echo "error: app profile lacks required app-proxy-provider entitlement" >&2
    exit 1
  fi
  case "$name" in
    *$'\r'*|*$'\n'*)
      echo "error: provisioning profile name contains a newline" >&2
      exit 1
      ;;
  esac

  install -m 0600 "$source" "$profile_dir/$uuid.mobileprovision"
  printf '%s_UUID=%s\n' "$prefix" "$uuid" >>"$GITHUB_ENV"
  printf '%s_NAME=%s\n' "$prefix" "$name" >>"$GITHUB_ENV"
  if [ "$expected_bundle" = com.privatedeploy.mobile ]; then
    validated_app_profile_name="$name"
  else
    validated_extension_profile_name="$name"
  fi
}

validated_app_profile_name=''
validated_extension_profile_name=''
validate_profile "$app_profile" 'com.privatedeploy.mobile' PRIVATEDEPLOY_IOS_APP_PROFILE
validate_profile "$extension_profile" 'com.privatedeploy.mobile.VPNExtension' PRIVATEDEPLOY_IOS_EXTENSION_PROFILE

plutil -lint "$export_options" >/dev/null
method="$(/usr/libexec/PlistBuddy -c 'Print :method' "$export_options")"
case "$method" in
  app-store|app-store-connect|ad-hoc|enterprise) ;;
  *) echo "error: ExportOptions.plist method '$method' is not a distribution method" >&2; exit 1 ;;
esac
# Exporting a verified IPA and uploading it to a store are separate external
# side effects. A signing secret must never turn a dry-run release workflow
# into an App Store Connect upload, so destination=upload is rejected here.
destination="$(/usr/libexec/PlistBuddy -c 'Print :destination' "$export_options" 2>/dev/null || printf export)"
if [ "$destination" != export ]; then
  echo "error: ExportOptions.plist destination must be 'export' (store upload is a separate authorized operation)" >&2
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :signingStyle' "$export_options")" != manual ]; then
  echo "error: ExportOptions.plist must use manual signing" >&2
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$export_options")" != "$PRIVATEDEPLOY_APPLE_TEAM_ID" ]; then
  echo "error: ExportOptions.plist teamID does not match PRIVATEDEPLOY_APPLE_TEAM_ID" >&2
  exit 1
fi
export_app_profile="$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.privatedeploy.mobile' "$export_options")"
export_extension_profile="$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.privatedeploy.mobile.VPNExtension' "$export_options")"
if [ "$export_app_profile" != "$validated_app_profile_name" ] || \
   [ "$export_extension_profile" != "$validated_extension_profile_name" ]; then
  echo "error: ExportOptions.plist profile names do not match the validated app/extension profiles" >&2
  exit 1
fi

# Add the isolated keychain to the search list without removing the runner's
# existing keychains (which Xcode/Flutter may need).
existing_keychains="$(security list-keychains -d user | tr -d '"')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain" $existing_keychains

printf 'PRIVATEDEPLOY_IOS_KEYCHAIN_PATH=%s\n' "$keychain" >>"$GITHUB_ENV"
printf 'PRIVATEDEPLOY_IOS_EXPORT_OPTIONS_PATH=%s\n' "$export_options" >>"$GITHUB_ENV"
echo "iOS signing identity and provisioning profiles passed preflight."
