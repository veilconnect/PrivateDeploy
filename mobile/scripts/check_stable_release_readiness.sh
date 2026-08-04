#!/usr/bin/env bash
# Linux-safe structural gate. It checks that stable mobile release machinery is
# present and that common local secret files are not tracked. It does not claim
# to validate Apple credentials, signing or physical devices.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

required_files=(
  .github/workflows/mobile-release.yml
  mobile/android/app/build.gradle
  mobile/ios/Runner.xcodeproj/project.pbxproj
  mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme
  mobile/ios/Runner/Runner.entitlements
  mobile/ios/VPNExtension/VPNExtension.entitlements
  mobile/ios/ExportOptions.example.plist
  mobile/scripts/prepare_android_release_signing.sh
  mobile/scripts/package_android_release.sh
  mobile/scripts/verify_aab_signature.sh
  mobile/scripts/test_android_aab_signature.sh
  mobile/scripts/prepare_ios_release_signing.sh
  mobile/scripts/package_ios_release.sh
  mobile/scripts/test_stable_release_config.sh
  LICENSE
  THIRD_PARTY_LICENSES.md
  third_party/THIRD_PARTY_NOTICES.txt
  third_party/sbom.spdx.json
)
for file in "${required_files[@]}"; do
  if [ ! -s "$file" ]; then
    echo "error: stable mobile release prerequisite is missing: $file" >&2
    exit 1
  fi
done

if ! jq -e '.spdxVersion and .name and .packages' third_party/sbom.spdx.json >/dev/null; then
  echo "error: third_party/sbom.spdx.json is not a minimally valid SPDX JSON document" >&2
  exit 1
fi

if git ls-files | grep -Eq '(^|/)(key\.properties|.*\.(jks|keystore|p12|pfx|mobileprovision))$'; then
  echo "error: signing key/profile material is tracked by git" >&2
  git ls-files | grep -E '(^|/)(key\.properties|.*\.(jks|keystore|p12|pfx|mobileprovision))$' >&2
  exit 1
fi

grep -q 'PRIVATEDEPLOY_REQUIRE_RELEASE_SIGNING' mobile/android/app/build.gradle
grep -q 'VPNExtension' mobile/ios/Runner.xcodeproj/project.pbxproj
grep -q 'com.apple.developer.networking.networkextension' mobile/ios/VPNExtension/VPNExtension.entitlements
grep -q 'com.apple.developer.networking.networkextension' mobile/ios/Runner/Runner.entitlements
grep -q 'packet-tunnel-provider' mobile/ios/VPNExtension/VPNExtension.entitlements
grep -q 'app-proxy-provider' mobile/ios/Runner/Runner.entitlements
grep -q 'PROVISIONING_PROFILE_SPECIFIER\[sdk=iphoneos\*\]' mobile/ios/Runner.xcodeproj/project.pbxproj
grep -q 'package_android_release.sh' .github/workflows/mobile-release.yml
grep -q 'package_ios_release.sh' .github/workflows/mobile-release.yml
grep -q 'openssl x509' mobile/scripts/prepare_ios_release_signing.sh
if grep -q 'find-certificate -a -Z' mobile/scripts/prepare_ios_release_signing.sh; then
  echo "error: iOS certificate pinning must compute SHA-256 from the exported identity certificate" >&2
  exit 1
fi

repo_version="$(tr -d '[:space:]' <VERSION)"
mobile_version="$(awk '/^version:/{print $2; exit}' mobile/pubspec.yaml)"
mobile_name="${mobile_version%+*}"
if [ "$repo_version" != "$mobile_name" ]; then
  echo "error: VERSION ($repo_version) and mobile pubspec ($mobile_name) differ" >&2
  exit 1
fi

echo "Static stable-mobile release readiness checks passed."
echo "Credential, signed-artifact and physical-device validation still require their dedicated release jobs."
