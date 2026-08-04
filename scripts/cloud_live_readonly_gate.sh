#!/usr/bin/env bash
set -euo pipefail

# Read-only stable-release smoke against the real Vultr and DigitalOcean APIs.
# It validates auth plus regions/plans/availability/instance-list operations;
# it never creates, modifies, or deletes cloud resources.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${PD_CLOUD_LIVE_OUT_DIR:-${ROOT_DIR}/output/cloud-live}"
REPORT_PATH="${PD_CLOUD_LIVE_REPORT:-${OUT_DIR}/readonly-report.json}"
TIMEOUT_SEC="${PD_CLOUD_LIVE_TIMEOUT_SEC:-45}"

require_secret() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "cloud live gate: required secret ${name} is not configured" >&2
    exit 2
  fi
}

require_secret VULTR_API_KEY
require_secret DIGITALOCEAN_API_KEY
command -v jq >/dev/null 2>&1 || { echo "cloud live gate: jq is required" >&2; exit 2; }

umask 077
mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d /tmp/privatedeploy-cloud-live.XXXXXX)"
TMP_REPORT="${TMP_DIR}/report.json"
trap 'rm -rf "$TMP_DIR"' EXIT

(
  cd "$ROOT_DIR"
  env \
    GOCACHE="${GOCACHE:-/tmp/privatedeploy-cloud-live-gocache}" \
    PRIVATEDEPLOY_BASE_PATH="$TMP_DIR" \
    PRIVATEDEPLOY_SECRET_STORE_DIR="${TMP_DIR}/secrets" \
    VULTR_API_KEY="$VULTR_API_KEY" \
    DIGITALOCEAN_API_KEY="$DIGITALOCEAN_API_KEY" \
    go run ./cmd/cloud-readonly-check \
      --providers vultr,digitalocean \
      --timeout-sec "$TIMEOUT_SEC" >"$TMP_REPORT"
)

# Defense in depth: reports are uploaded as CI evidence, so prove neither raw
# credential was copied into provider error text or JSON output.
if rg -q -F -- "$VULTR_API_KEY" "$TMP_REPORT" || rg -q -F -- "$DIGITALOCEAN_API_KEY" "$TMP_REPORT"; then
  echo "cloud live gate: refusing to publish a report containing a credential" >&2
  exit 1
fi

jq -e '
  .summary.total == 2 and
  .summary.has_key == 2 and
  .summary.live_api_ok == 2 and
  (.providers | length == 2) and
  ([.providers[] |
    .hasKey and .liveApiOk and
    .regions.ok and .plans.ok and .availability.ok and .instances.ok
  ] | all)
' "$TMP_REPORT" >/dev/null || {
  jq '{generatedAt, summary, providers}' "$TMP_REPORT" >&2
  echo "cloud live gate: one or more required provider operations failed" >&2
  exit 1
}

cp "$TMP_REPORT" "$REPORT_PATH"
chmod 0600 "$REPORT_PATH"
jq -r '.providers[] | "\(.provider): regions=\(.regions.count), plans=\(.plans.count), availability=\(.availability.count), instances=\(.instances.count)"' "$REPORT_PATH"
echo "cloud live gate OK: ${REPORT_PATH}"
