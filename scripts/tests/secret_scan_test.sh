#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d /tmp/privatedeploy-secret-scan-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts" "$TMP/mobile/android"
cp "$ROOT/scripts/secret_scan.sh" "$TMP/scripts/secret_scan.sh"
(
  cd "$TMP"
  git init -q
  printf 'mobile/android/key.properties\n' >.gitignore
  printf 'safe fixture\n' >README.md
  printf 'storePassword=not-a-real-secret\n' >mobile/android/key.properties
  git add README.md .gitignore scripts/secret_scan.sh
  git add -f mobile/android/key.properties
  if bash scripts/secret_scan.sh >/tmp/privatedeploy-secret-scan-test.log 2>&1; then
    echo 'secret scan accepted a force-added ignored key.properties' >&2
    exit 1
  fi
  grep -q 'tracked signing credential/configuration' /tmp/privatedeploy-secret-scan-test.log
)

echo 'secret scan tracked-ignore regression test OK'
