#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/privatedeploy-cloud-gate-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/out"

write_fake_go() {
  local live_ok="$1"
  cat >"${TMP_DIR}/bin/go" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" != "run" || "\${2:-}" != "./cmd/cloud-readonly-check" ]]; then
  echo "gate invoked an unexpected checker: \$*" >&2
  exit 64
fi
cat <<'JSON'
{
  "generatedAt": "2026-07-13T00:00:00Z",
  "summary": {"total": 2, "has_key": 2, "live_api_ok": ${live_ok}, "missing_key": 0, "auth_or_api_err": 0},
  "providers": [
    {"provider":"vultr","hasKey":true,"liveApiOk":true,"regions":{"ok":true,"count":1},"plans":{"ok":true,"count":1},"availability":{"ok":true,"count":1},"instances":{"ok":true,"count":0}},
    {"provider":"digitalocean","hasKey":true,"liveApiOk":true,"regions":{"ok":true,"count":1},"plans":{"ok":true,"count":1},"availability":{"ok":true,"count":1},"instances":{"ok":true,"count":0}}
  ]
}
JSON
EOF
  chmod +x "${TMP_DIR}/bin/go"
}

write_fake_go 2
PATH="${TMP_DIR}/bin:${PATH}" \
VULTR_API_KEY="test-vultr-key" \
DIGITALOCEAN_API_KEY="test-do-key" \
PD_CLOUD_LIVE_OUT_DIR="${TMP_DIR}/out" \
PD_CLOUD_LIVE_REPORT="${TMP_DIR}/out/success.json" \
  bash "${ROOT_DIR}/scripts/cloud_live_readonly_gate.sh" >/dev/null
test -s "${TMP_DIR}/out/success.json"

write_fake_go 1
if PATH="${TMP_DIR}/bin:${PATH}" \
  VULTR_API_KEY="test-vultr-key" \
  DIGITALOCEAN_API_KEY="test-do-key" \
  PD_CLOUD_LIVE_OUT_DIR="${TMP_DIR}/out" \
  PD_CLOUD_LIVE_REPORT="${TMP_DIR}/out/failure.json" \
  bash "${ROOT_DIR}/scripts/cloud_live_readonly_gate.sh" >/dev/null 2>&1; then
  echo "expected a failed provider report to fail the gate" >&2
  exit 1
fi

echo "cloud live read-only gate tests OK"
