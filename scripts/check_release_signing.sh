#!/usr/bin/env bash
# Static guard against accidentally weakening the stable-release signing gate.
# This does not replace a real signed tag build; it verifies that the workflow
# still contains the credential gate, signing, notarization and pre-archive
# verification commands documented in docs/RELEASE-SIGNING.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

fail() {
  echo "check_release_signing FAILED: $1" >&2
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "missing $WORKFLOW"

required_fragments=(
  "Stable release signing preflight"
  "Import-PfxCertificate"
  "signtool.exe"
  "signTool.FullName sign"
  "signTool.FullName verify"
  "Get-AuthenticodeSignature"
  "WINDOWS_SIGNING_CERT_SHA256"
  "codesign --force --options runtime --timestamp"
  "codesign --verify --deep --strict"
  "xcrun notarytool submit"
  "--wait"
  "xcrun stapler staple"
  "xcrun stapler validate"
  "spctl --assess --type execute"
  "MACOS_SIGNING_CERT_SHA256"
  "APPLE_DEVELOPER_TEAM_ID"
  "ditto -x -k"
  "actions/attest-build-provenance@v4"
  "id-token: write"
  "attestations: write"
  "run: bash scripts/secret_scan.sh"
  "PD_WEBSITE_DIR=\"\$PWD/release-website\""
  "node website/tools/render-localized-pages.js --update-release"
  "name: website-release-handoff-\${{ github.ref_name }}"
)

for fragment in "${required_fragments[@]}"; do
  grep -Fq -- "$fragment" "$WORKFLOW" || fail "workflow is missing: $fragment"
done

if grep -Fq -- "ALLOW_UNSIGNED_RELEASE" "$WORKFLOW"; then
  fail "stable-only release workflow must not contain an unsigned-release bypass"
fi

# A tag cannot know the hashes of its own timestamped signed/notarized
# archives before those archives are built. Requiring the committed website
# manifest to match the incoming tag would make the release graph circular.
quality_section="$(sed -n '/^  Quality-Gate:/,/^  Build-Frontend:/p' "$WORKFLOW")"
if grep -Fq -- "PD_EXPECT_VERSION" <<<"$quality_section"; then
  fail "Quality-Gate must not require precommitted hashes for the incoming tag"
fi

line_of() {
  local fragment=$1
  grep -nF -- "$fragment" "$WORKFLOW" | head -n1 | cut -d: -f1
}

windows_sign_line="$(line_of "signTool.FullName sign")"
windows_verify_line="$(line_of "signTool.FullName verify")"
windows_pack_line="$(line_of "Compress-Archive")"
[[ "$windows_sign_line" -lt "$windows_verify_line" && "$windows_verify_line" -lt "$windows_pack_line" ]] ||
  fail "Windows signing and verification must happen before Compress-Archive"

mac_sign_line="$(line_of "codesign --force --options runtime --timestamp")"
mac_notary_line="$(line_of "xcrun notarytool submit")"
mac_staple_line="$(line_of "xcrun stapler staple")"
mac_pack_line="$(line_of "ditto -c -k --sequesterRsrc")"
[[ "$mac_sign_line" -lt "$mac_notary_line" && "$mac_notary_line" -lt "$mac_staple_line" && "$mac_staple_line" -lt "$mac_pack_line" ]] ||
  fail "macOS signing, notarization and stapling must happen before zip packaging"

website_update_line="$(line_of "node website/tools/render-localized-pages.js --update-release")"
website_verify_line="$(line_of "node website/tools/render-localized-pages.js --verify-checksums")"
release_create_line="$(line_of "name: Create Release")"
[[ "$website_update_line" -lt "$website_verify_line" && "$website_verify_line" -lt "$release_create_line" ]] ||
  fail "website handoff must be generated and verified from built artifacts before creating the release"

echo "Release signing workflow static checks passed."
