#!/usr/bin/env bash
# Decode and validate the Android release keystore in an ephemeral directory.
# This script is intended for CI; it never writes signing material into the repo.
set -euo pipefail

required=(
  PRIVATEDEPLOY_ANDROID_KEYSTORE_BASE64
  PRIVATEDEPLOY_ANDROID_KEY_ALIAS
  PRIVATEDEPLOY_ANDROID_KEY_PASSWORD
  PRIVATEDEPLOY_ANDROID_STORE_PASSWORD
  PRIVATEDEPLOY_ANDROID_SIGNING_CERT_SHA256
  RUNNER_TEMP
  GITHUB_ENV
)

for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "error: required Android release secret/environment value '$name' is missing" >&2
    exit 1
  fi
done

umask 077
keystore="$RUNNER_TEMP/privatedeploy-release.jks"
if ! printf '%s' "$PRIVATEDEPLOY_ANDROID_KEYSTORE_BASE64" | base64 --decode >"$keystore"; then
  echo "error: PRIVATEDEPLOY_ANDROID_KEYSTORE_BASE64 is not valid base64" >&2
  rm -f "$keystore"
  exit 1
fi

if [ ! -s "$keystore" ]; then
  echo "error: decoded Android keystore is empty" >&2
  exit 1
fi

keytool -list \
  -keystore "$keystore" \
  -storepass "$PRIVATEDEPLOY_ANDROID_STORE_PASSWORD" \
  -alias "$PRIVATEDEPLOY_ANDROID_KEY_ALIAS" >/dev/null

cert_der="$RUNNER_TEMP/privatedeploy-android-release.der"
keytool -exportcert \
  -keystore "$keystore" \
  -storepass "$PRIVATEDEPLOY_ANDROID_STORE_PASSWORD" \
  -alias "$PRIVATEDEPLOY_ANDROID_KEY_ALIAS" \
  -file "$cert_der" >/dev/null
normalize_digest() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]'
}
expected="$(normalize_digest "$PRIVATEDEPLOY_ANDROID_SIGNING_CERT_SHA256")"
actual="$(sha256sum "$cert_der" | awk '{print toupper($1)}')"
rm -f "$cert_der"
if ! [[ "$expected" =~ ^[0-9A-F]{64}$ ]] || [ "$actual" != "$expected" ]; then
  echo "error: Android keystore alias does not match the pinned release certificate SHA-256" >&2
  exit 1
fi

# Only a non-secret path is exported. Passwords remain masked GitHub secrets.
printf 'PRIVATEDEPLOY_ANDROID_STORE_FILE=%s\n' "$keystore" >>"$GITHUB_ENV"
printf 'PRIVATEDEPLOY_REQUIRE_RELEASE_SIGNING=true\n' >>"$GITHUB_ENV"
echo "Android release keystore preflight passed."
