#!/usr/bin/env bash
#
# Verifies that the release build configuration actually injects the app
# version via `-ldflags "-X privatedeploy/bridge.AppVersion=..."`:
#
#   1. Static: .github/workflows/release.yml injects it on every platform
#      build (linux / macos / windows).
#   2. Static: every local packaging script injects it too.
#   3. Dynamic: compiles a tiny probe that prints bridge.AppVersion, once
#      with the ldflags -X flag (must print the injected value) and once
#      without (must print the "dev" default that check_versions.sh pins).
#
# Run from anywhere: bash scripts/check_release_ldflags.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LDFLAG_PATTERN='-X privatedeploy/bridge.AppVersion='

fail() {
  echo "check_release_ldflags FAILED: $1" >&2
  exit 1
}

# ── 1. release workflow must inject the version on all three platform builds ──
RELEASE_YML="$ROOT_DIR/.github/workflows/release.yml"
[[ -f "$RELEASE_YML" ]] || fail "missing $RELEASE_YML"
COUNT=0
for job in Build-Windows Build-macOS Build-Linux; do
  block="$(sed -n "/^  ${job}:/,/^  [A-Za-z][A-Za-z-]*:/p" "$RELEASE_YML")"
  grep -q -- "$LDFLAG_PATTERN" <<<"$block" || fail "release.yml job $job does not inject '$LDFLAG_PATTERN'"
  grep -q -- 'AppVersion=.*GITHUB_REF_NAME' <<<"$block" || fail "release.yml job $job does not inject the validated release tag"
  COUNT=$((COUNT + 1))
done

# ── 2. local packaging scripts must inject it too ──────────────────
PACKAGING_SCRIPTS=(
  scripts/build-all.sh
  scripts/build-linux-packages.sh
  scripts/build-macos-dmg.sh
  scripts/build-windows-exe.sh
  scripts/build-windows-installer.sh
  scripts/jammy-build/in-container-build.sh
)
for rel in "${PACKAGING_SCRIPTS[@]}"; do
  [[ -f "$ROOT_DIR/$rel" ]] || fail "missing packaging script $rel"
  grep -q -- "$LDFLAG_PATTERN" "$ROOT_DIR/$rel" || fail "$rel does not inject '$LDFLAG_PATTERN'"
done

# ── 3. dynamic probe: the -X flag really lands in the binary ───────
# tmp/ is gitignored and excluded from quality_gate's `go list`, so a
# transient probe package there never leaks into tests or releases.
PROBE_NAME="ldflags-probe-$$"
PROBE_DIR="$ROOT_DIR/tmp/$PROBE_NAME"
mkdir -p "$PROBE_DIR"
trap 'rm -rf "$PROBE_DIR"' EXIT

cat > "$PROBE_DIR/main.go" <<'EOF'
package main

import (
	"fmt"

	"privatedeploy/bridge"
)

func main() {
	fmt.Print(bridge.AppVersion)
}
EOF

TEST_VERSION="test-1.2.3"
(cd "$ROOT_DIR" && go build -ldflags "-X privatedeploy/bridge.AppVersion=$TEST_VERSION" -o "$PROBE_DIR/probe" "./tmp/$PROBE_NAME")
GOT="$("$PROBE_DIR/probe")"
[[ "$GOT" == "$TEST_VERSION" ]] || fail "probe built with ldflags printed '$GOT', expected '$TEST_VERSION' — version injection is broken"

(cd "$ROOT_DIR" && go build -o "$PROBE_DIR/probe-default" "./tmp/$PROBE_NAME")
GOT_DEFAULT="$("$PROBE_DIR/probe-default")"
[[ "$GOT_DEFAULT" == "dev" ]] || fail "probe built WITHOUT ldflags printed '$GOT_DEFAULT', expected 'dev' — bridge.AppVersion default drifted (see check_versions.sh)"

echo "Release ldflags check OK: release.yml injects on $COUNT builds, all packaging scripts inject, probe printed '$GOT' (with -X) / '$GOT_DEFAULT' (default)"
