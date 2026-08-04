#!/usr/bin/env bash
# Verify that every payload entry in an Android App Bundle is covered by its
# JAR signature. `jarsigner -verify` alone exits 0 for a signed archive that
# had an unsigned file appended after signing, so its verbose report must also
# be checked explicitly.
set -euo pipefail

AAB="${1:-}"
if [[ -z "$AAB" || ! -s "$AAB" ]]; then
  echo 'error: path to a non-empty AAB is required' >&2
  exit 1
fi

if ! report="$(LC_ALL=C jarsigner -verify -verbose -certs "$AAB" 2>&1)"; then
  printf '%s\n' "$report" >&2
  echo 'error: AAB JAR signature verification failed' >&2
  exit 1
fi
printf '%s\n' "$report"

if grep -Fqi 'contains unsigned entries' <<<"$report" || \
   grep -Eq '^[[:space:]]*\?[[:space:]]+[0-9]+[[:space:]]' <<<"$report"; then
  echo 'error: AAB contains one or more payload entries not covered by the signature' >&2
  exit 1
fi

if ! grep -Fq 'jar verified.' <<<"$report"; then
  echo 'error: jarsigner did not confirm the AAB signature' >&2
  exit 1
fi
