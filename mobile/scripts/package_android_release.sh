#!/usr/bin/env bash
# Verify signed Android outputs and create versioned, checksummed handoff files.
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$MOBILE_DIR/.." && pwd)"
APK="${1:-$MOBILE_DIR/build/app/outputs/flutter-apk/app-release.apk}"
AAB="${2:-$MOBILE_DIR/build/app/outputs/bundle/release/app-release.aab}"
OUTPUT_DIR="${3:-$MOBILE_DIR/build/release-ready/android}"

if [ -z "${PRIVATEDEPLOY_ANDROID_SIGNING_CERT_SHA256:-}" ]; then
  echo "error: PRIVATEDEPLOY_ANDROID_SIGNING_CERT_SHA256 is required to pin the release certificate" >&2
  exit 1
fi

for file in "$APK" "$AAB"; do
  if [ ! -s "$file" ]; then
    echo "error: expected Android release output is missing: $file" >&2
    exit 1
  fi
done

if ! command -v apksigner >/dev/null 2>&1; then
  echo "error: apksigner is required to verify the APK" >&2
  exit 1
fi

apk_report="$(apksigner verify --verbose --print-certs "$APK")"
printf '%s\n' "$apk_report"
apk_digest="$(printf '%s\n' "$apk_report" | awk -F': ' '/Signer #1 certificate SHA-256 digest:/{print $2; exit}')"
apk_dn="$(printf '%s\n' "$apk_report" | awk -F': ' '/Signer #1 certificate DN:/{print $2; exit}')"

aab_report="$(keytool -printcert -jarfile "$AAB")"
# Android upload certificates are commonly self-signed, so jarsigner -strict
# would reject a valid AAB for trust-chain warnings. The dedicated verifier
# accepts those chain warnings but rejects any unsigned appended payload entry.
"$MOBILE_DIR/scripts/verify_aab_signature.sh" "$AAB"
aab_entries="$(unzip -Z1 "$AAB")"
if ! grep -Eq '^META-INF/.*\.(RSA|DSA|EC)$' <<<"$aab_entries"; then
  echo "error: AAB has no JAR signature block" >&2
  exit 1
fi
aab_digest="$(printf '%s\n' "$aab_report" | awk -F': ' '/SHA256:/{print $2; exit}')"

normalize_digest() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]'
}

expected="$(normalize_digest "$PRIVATEDEPLOY_ANDROID_SIGNING_CERT_SHA256")"
actual_apk="$(normalize_digest "$apk_digest")"
actual_aab="$(normalize_digest "$aab_digest")"
if ! [[ "$expected" =~ ^[0-9A-F]{64}$ ]]; then
  echo "error: expected Android certificate SHA-256 must contain exactly 64 hexadecimal characters" >&2
  exit 1
fi
if [ "$actual_apk" != "$expected" ] || [ "$actual_aab" != "$expected" ]; then
  echo "error: APK/AAB certificate does not match the pinned release certificate" >&2
  exit 1
fi
if printf '%s' "$apk_dn" | grep -qi 'CN=Android Debug'; then
  echo "error: debug signing certificate detected on stable APK" >&2
  exit 1
fi

pubspec_version="$(awk '/^version:/{print $2; exit}' "$MOBILE_DIR/pubspec.yaml")"
version_name="${pubspec_version%+*}"
build_number="${pubspec_version#*+}"
if [ -z "$version_name" ] || [ "$build_number" = "$pubspec_version" ]; then
  echo "error: mobile/pubspec.yaml must contain version X.Y.Z+BUILD" >&2
  exit 1
fi
if ! command -v aapt >/dev/null 2>&1; then
  echo "error: aapt is required to verify embedded Android version metadata" >&2
  exit 1
fi
if [ -z "${BUNDLETOOL_JAR:-}" ] || [ ! -s "$BUNDLETOOL_JAR" ]; then
  echo "error: checksum-pinned BUNDLETOOL_JAR is required to verify AAB metadata" >&2
  exit 1
fi
apk_badging="$(aapt dump badging "$APK" | grep '^package:' | head -n 1)"
apk_package="$(printf '%s' "$apk_badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
apk_version_code="$(printf '%s' "$apk_badging" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
apk_version_name="$(printf '%s' "$apk_badging" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
if [ "$apk_package" != com.privatedeploy.mobile ] || \
   [ "$apk_version_code" != "$build_number" ] || \
   [ "$apk_version_name" != "$version_name" ]; then
  echo "error: APK package/version metadata does not match the release source" >&2
  exit 1
fi

aab_package="$(java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$AAB" --xpath='/manifest/@package')"
aab_version_code="$(java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$AAB" --xpath='/manifest/@android:versionCode')"
aab_version_name="$(java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$AAB" --xpath='/manifest/@android:versionName')"
if [ "$aab_package" != com.privatedeploy.mobile ] || \
   [ "$aab_version_code" != "$build_number" ] || \
   [ "$aab_version_name" != "$version_name" ]; then
  echo "error: AAB package/version metadata does not match the release source" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
apk_name="PrivateDeploy-android-${version_name}+${build_number}.apk"
aab_name="PrivateDeploy-android-${version_name}+${build_number}.aab"
install -m 0644 "$APK" "$OUTPUT_DIR/$apk_name"
install -m 0644 "$AAB" "$OUTPUT_DIR/$aab_name"
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
license_name='PrivateDeploy-android-LICENSE.txt'
license_summary_name='PrivateDeploy-android-THIRD-PARTY-LICENSES.md'
notices_name='PrivateDeploy-android-THIRD-PARTY-NOTICES.txt'
sbom_name='PrivateDeploy-android-SBOM.spdx.json'
install -m 0644 "${legal_sources[0]}" "$OUTPUT_DIR/$license_name"
install -m 0644 "${legal_sources[1]}" "$OUTPUT_DIR/$license_summary_name"
install -m 0644 "${legal_sources[2]}" "$OUTPUT_DIR/$notices_name"
install -m 0644 "${legal_sources[3]}" "$OUTPUT_DIR/$sbom_name"
(
  cd "$OUTPUT_DIR"
  sha256sum "$apk_name" "$aab_name" "$license_name" "$license_summary_name" "$notices_name" "$sbom_name" >checksums-android.sha256
  sha256sum --check checksums-android.sha256
)

echo "Signed Android release package is ready in $OUTPUT_DIR"
