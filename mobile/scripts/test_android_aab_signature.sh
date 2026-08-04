#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d /tmp/privatedeploy-aab-signature.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

printf 'signed payload\n' >"$TMP/payload.txt"
(cd "$TMP" && zip -q fixture.aab payload.txt)
keytool -genkeypair -alias fixture -keystore "$TMP/fixture.jks" \
  -storepass changeit -keypass changeit -dname 'CN=PrivateDeploy Test Only' \
  -keyalg RSA -validity 1 >/dev/null 2>&1
jarsigner -keystore "$TMP/fixture.jks" -storepass changeit -keypass changeit \
  "$TMP/fixture.aab" fixture >/dev/null 2>&1

bash "$ROOT/mobile/scripts/verify_aab_signature.sh" "$TMP/fixture.aab" >/dev/null

printf 'unsigned appended payload\n' >"$TMP/unsigned.txt"
(cd "$TMP" && zip -q fixture.aab unsigned.txt)
if bash "$ROOT/mobile/scripts/verify_aab_signature.sh" "$TMP/fixture.aab" >/dev/null 2>&1; then
  echo 'error: AAB verifier accepted an unsigned appended entry' >&2
  exit 1
fi

echo 'AAB signed-entry regression test passed.'
