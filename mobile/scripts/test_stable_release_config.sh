#!/usr/bin/env bash
# Credential-free syntax and regression tests for stable mobile release config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

scripts=(
  mobile/scripts/prepare_android_release_signing.sh
  mobile/scripts/package_android_release.sh
  mobile/scripts/verify_aab_signature.sh
  mobile/scripts/test_android_aab_signature.sh
  mobile/scripts/prepare_ios_release_signing.sh
  mobile/scripts/package_ios_release.sh
  mobile/scripts/check_stable_release_readiness.sh
)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

ruby -e "require 'yaml'; YAML.parse_file(ARGV.fetch(0))" .github/workflows/mobile-release.yml
xmllint --noout \
  mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme \
  mobile/ios/ExportOptions.example.plist \
  mobile/ios/Runner/Runner.entitlements \
  mobile/ios/VPNExtension/VPNExtension.entitlements

if grep -En 'Build iOS \(no codesign\)|app-release-ipa|flutter build (apk|appbundle) --release' \
  .github/workflows/mobile-build-android.yml \
  .github/workflows/mobile-build-ios.yml; then
  echo "error: ordinary CI workflows must not produce release-named unsigned mobile artifacts" >&2
  exit 1
fi

grep -q "PRIVATEDEPLOY_REQUIRE_RELEASE_SIGNING=true" mobile/scripts/prepare_android_release_signing.sh
grep -q "PRIVATEDEPLOY_REQUIRE_RELEASE_SIGNING" mobile/android/app/build.gradle
grep -q "verify_aab_signature.sh" mobile/scripts/package_android_release.sh
grep -q "checksum-pinned BUNDLETOOL_JAR" mobile/scripts/package_android_release.sh
grep -q "bundletool-all-1.18.3.jar" .github/workflows/mobile-release.yml
grep -q "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29" .github/workflows/mobile-release.yml
grep -q "PRIVATEDEPLOY_IOS_APP_PROFILE_BASE64" .github/workflows/mobile-release.yml
grep -q "PRIVATEDEPLOY_IOS_EXTENSION_PROFILE_BASE64" .github/workflows/mobile-release.yml
grep -q "packet-tunnel-provider" mobile/scripts/prepare_ios_release_signing.sh
grep -q "destination must be 'export'" mobile/scripts/prepare_ios_release_signing.sh
grep -q "codesign --verify" mobile/scripts/package_ios_release.sh
grep -q "Unexpected unchecksummed mobile release file" .github/workflows/mobile-release.yml
grep -q 'GH_REPO: \${{ github.repository }}' .github/workflows/mobile-release.yml
grep -q "Stable release asset already exists and will not be replaced" .github/workflows/mobile-release.yml
if grep -q -- '--clobber' .github/workflows/mobile-release.yml; then
  echo 'error: stable mobile assets must be immutable once published' >&2
  exit 1
fi

environment_count="$(grep -c '^    environment: stable-release$' .github/workflows/mobile-release.yml)"
if [ "$environment_count" -ne 3 ]; then
  echo "error: Android, iOS, and publish jobs must all use the protected stable-release environment" >&2
  exit 1
fi
grep -q '^      artifact-metadata: write$' .github/workflows/mobile-release.yml
attest_line="$(grep -n 'actions/attest-build-provenance@v4' .github/workflows/mobile-release.yml | cut -d: -f1)"
upload_line="$(grep -n 'gh release upload' .github/workflows/mobile-release.yml | cut -d: -f1)"
if [ -z "$attest_line" ] || [ -z "$upload_line" ] || [ "$attest_line" -ge "$upload_line" ]; then
  echo "error: provenance attestation must complete before GitHub release upload" >&2
  exit 1
fi

echo "Stable mobile release configuration syntax/regression tests passed."
