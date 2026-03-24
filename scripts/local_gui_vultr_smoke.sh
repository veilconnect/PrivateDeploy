#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="${APP_BIN:-${ROOT_DIR}/build/bin/PrivateDeploy}"
API_KEY_FILE="${VULTR_API_KEY_FILE:-/tmp/vultr_api_key.txt}"
SMOKE_REGION="${SMOKE_REGION:-nrt}"
SMOKE_PLAN="${SMOKE_PLAN:-vc2-1c-1gb}"
TIMEOUT_CREATE_SEC="${TIMEOUT_CREATE_SEC:-240}"
TIMEOUT_PORT_SEC="${TIMEOUT_PORT_SEC:-180}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${ROOT_DIR}/output/gui-smoke}"
RUN_ID="${RUN_ID:-local-gui-vultr-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
APP_BASE="${APP_BASE:-$(mktemp -d "${TMPDIR:-/tmp}/pd-local-gui-smoke-XXXXXX")}"
CURL_ERROR_LOG="${RUN_DIR}/curl.err"
WORKBENCH_DEPLOY_X="${WORKBENCH_DEPLOY_X:-760}"
WORKBENCH_DEPLOY_Y="${WORKBENCH_DEPLOY_Y:-195}"
CREATE_DEPLOY_X="${CREATE_DEPLOY_X:-260}"
CREATE_DEPLOY_Y="${CREATE_DEPLOY_Y:-319}"
VULTR_API_BASE="https://api.vultr.com/v2"
CURL_COMMON_ARGS=(
  --connect-timeout 10
  --max-time 30
  --retry 3
  --retry-delay 2
  --retry-all-errors
)
CURL_STATUS_ARGS=(
  --connect-timeout 10
  --max-time 15
)

mkdir -p "${RUN_DIR}"
: > "${CURL_ERROR_LOG}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in jq curl xdotool xwininfo import xvfb-run python3 timeout; do
  require_cmd "${cmd}"
done

if [[ ! -x "${APP_BIN}" ]]; then
  echo "App binary not found or not executable: ${APP_BIN}" >&2
  exit 1
fi

if [[ ! -s "${API_KEY_FILE}" ]]; then
  echo "Vultr API key file not found or empty: ${API_KEY_FILE}" >&2
  exit 1
fi

VULTR_API_KEY="$(tr -d '\r\n' < "${API_KEY_FILE}")"
if [[ -z "${VULTR_API_KEY}" ]]; then
  echo "Vultr API key is empty after trimming: ${API_KEY_FILE}" >&2
  exit 1
fi

if [[ "${PD_GUI_SMOKE_IN_XVFB:-0}" != "1" ]]; then
  exec xvfb-run -a env PD_GUI_SMOKE_IN_XVFB=1 "$0" "$@"
fi

APP_PID=""
INSTANCE_ID=""
INSTANCE_LABEL=""
INSTANCE_IP=""
INSTANCE_REGION=""
INSTANCE_PLAN=""
DESTROYED="0"
WINDOW_ID=""
PROXY_SNAPSHOT_SUPPORTED="0"

snapshot_proxy() {
  local target="$1"
  if command -v gsettings >/dev/null 2>&1; then
    {
      echo "mode=$(gsettings get org.gnome.system.proxy mode)"
      echo "http_host=$(gsettings get org.gnome.system.proxy.http host)"
      echo "http_port=$(gsettings get org.gnome.system.proxy.http port)"
      echo "socks_host=$(gsettings get org.gnome.system.proxy.socks host)"
      echo "socks_port=$(gsettings get org.gnome.system.proxy.socks port)"
    } > "${target}"
    PROXY_SNAPSHOT_SUPPORTED="1"
  else
    echo "gsettings-unavailable" > "${target}"
  fi
}

vultr_request() {
  local method="$1"
  local path="$2"
  shift 2
  curl "${CURL_COMMON_ARGS[@]}" -fsS -X "${method}" -H "Authorization: Bearer ${VULTR_API_KEY}" \
    "$@" "${VULTR_API_BASE}${path}" 2>> "${CURL_ERROR_LOG}"
}

destroy_instance() {
  if [[ -z "${INSTANCE_ID}" || "${DESTROYED}" == "1" ]]; then
    return 0
  fi

  for attempt in $(seq 1 30); do
    if [[ "${attempt}" == "1" || $(( attempt % 4 )) -eq 0 ]]; then
      curl "${CURL_COMMON_ARGS[@]}" -fsS -X DELETE -H "Authorization: Bearer ${VULTR_API_KEY}" \
        "${VULTR_API_BASE}/instances/${INSTANCE_ID}" >/dev/null 2>> "${CURL_ERROR_LOG}" || true
    fi

    local status_code
    status_code="$(
      curl "${CURL_STATUS_ARGS[@]}" -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" \
        "${VULTR_API_BASE}/instances/${INSTANCE_ID}" 2>> "${CURL_ERROR_LOG}" || true
    )"
    if [[ "${status_code}" == "404" ]]; then
      DESTROYED="1"
      return 0
    fi
    sleep 5
  done

  echo "Destroy polling did not reach 404 for ${INSTANCE_ID}" >&2
  return 1
}

on_exit() {
  local exit_code=$?
  if [[ -n "${APP_PID}" ]]; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
  fi
  snapshot_proxy "${RUN_DIR}/proxy.after"
  if [[ -n "${INSTANCE_ID}" && "${DESTROYED}" != "1" ]]; then
    destroy_instance || true
  fi
  if [[ "${exit_code}" -ne 0 ]]; then
    echo "Smoke test failed. Artifacts: ${RUN_DIR}" >&2
    echo "App base kept at: ${APP_BASE}" >&2
  fi
}
trap on_exit EXIT

echo "Artifacts: ${RUN_DIR}"
echo "App base:   ${APP_BASE}"

snapshot_proxy "${RUN_DIR}/proxy.before"

mkdir -p "${APP_BASE}/data/cloud" "${APP_BASE}/secrets"
cp "${APP_BIN}" "${APP_BASE}/PrivateDeploy"
chmod +x "${APP_BASE}/PrivateDeploy"

cat > "${APP_BASE}/data/user.yaml" <<'YAML'
width: 800
height: 510
webviewGpuPolicy: 1
autoSetSystemProxy: false
systemProxyPolicyInitialized: true
systemProxyManaged: false
systemProxyBackup: ""
pages:
  - Workbench
YAML

export APP_BASE VULTR_API_KEY SMOKE_REGION SMOKE_PLAN
python3 - <<'PY'
import json
import os

base = os.environ["APP_BASE"]
config = {
    "provider": "vultr",
    "apiKey": os.environ["VULTR_API_KEY"],
    "defaultRegion": os.environ["SMOKE_REGION"],
    "defaultPlan": os.environ["SMOKE_PLAN"],
    "extra": {},
}

path = os.path.join(base, "data", "cloud", "vultr-config.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
PY

export PRIVATEDEPLOY_SECRET_STORE_DIR="${APP_BASE}/secrets"
export GDK_BACKEND="x11"
export LIBGL_ALWAYS_SOFTWARE="1"

"${APP_BASE}/PrivateDeploy" > "${RUN_DIR}/app.out" 2> "${RUN_DIR}/app.err" &
APP_PID=$!

for _ in $(seq 1 60); do
  WINDOW_ID="$(xdotool search --onlyvisible --name "PrivateDeploy" 2>/dev/null | head -n1 || true)"
  if [[ -n "${WINDOW_ID}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${WINDOW_ID}" ]]; then
  echo "Failed to find PrivateDeploy window" >&2
  exit 1
fi

sleep 8
import -window root "${RUN_DIR}/workbench.png"
import -window "${WINDOW_ID}" "${RUN_DIR}/workbench-window.png"

xdotool mousemove --window "${WINDOW_ID}" "${WORKBENCH_DEPLOY_X}" "${WORKBENCH_DEPLOY_Y}" click 1
sleep 6
import -window root "${RUN_DIR}/cloud.png"
import -window "${WINDOW_ID}" "${RUN_DIR}/cloud-window.png"

NODES_FILE="${APP_BASE}/data/cloud/vultr-nodes.json"
BASELINE_IDS_FILE="${RUN_DIR}/baseline-instance-ids.txt"
if [[ -f "${NODES_FILE}" ]]; then
  jq -r '.[].instanceId' "${NODES_FILE}" | sort -u > "${BASELINE_IDS_FILE}"
else
  : > "${BASELINE_IDS_FILE}"
fi

xdotool mousemove --window "${WINDOW_ID}" "${CREATE_DEPLOY_X}" "${CREATE_DEPLOY_Y}" click 1
sleep 2
import -window root "${RUN_DIR}/after-create.png"
import -window "${WINDOW_ID}" "${RUN_DIR}/after-create-window.png"

if ! grep -q "CreateCloudInstanceTyped called" "${RUN_DIR}/app.err"; then
  for _ in $(seq 1 30); do
    if grep -q "CreateCloudInstanceTyped called" "${RUN_DIR}/app.err"; then
      break
    fi
    sleep 1
  done
fi

NEW_ID_FILE="${RUN_DIR}/new-instance-id.txt"
: > "${NEW_ID_FILE}"

create_attempts=$(( TIMEOUT_CREATE_SEC / 5 ))
if (( create_attempts < 1 )); then
  create_attempts=1
fi

for _ in $(seq 1 "${create_attempts}"); do
  if [[ -f "${NODES_FILE}" ]]; then
    CURRENT_IDS="$(jq -r '.[].instanceId' "${NODES_FILE}" | sort -u)"
    while IFS= read -r candidate; do
      [[ -z "${candidate}" ]] && continue
      if ! grep -qx "${candidate}" "${BASELINE_IDS_FILE}"; then
        echo "${candidate}" > "${NEW_ID_FILE}"
        break 2
      fi
    done <<< "${CURRENT_IDS}"
  fi
  sleep 5
done

INSTANCE_ID="$(tr -d '\r\n' < "${NEW_ID_FILE}")"
if [[ -z "${INSTANCE_ID}" ]]; then
  echo "Failed to detect new instance in ${NODES_FILE}" >&2
  exit 1
fi

NODE_JSON_FILE="${RUN_DIR}/node.json"
jq --arg id "${INSTANCE_ID}" '.[] | select(.instanceId == $id)' "${NODES_FILE}" > "${NODE_JSON_FILE}"

INSTANCE_LABEL="$(jq -r '.label' "${NODE_JSON_FILE}")"
INSTANCE_REGION="$(jq -r '.region' "${NODE_JSON_FILE}")"
INSTANCE_PLAN="$(jq -r '.plan' "${NODE_JSON_FILE}")"

STATUS_JSON_FILE="${RUN_DIR}/instance-status.json"
for _ in $(seq 1 "${create_attempts}"); do
  if vultr_request GET "/instances/${INSTANCE_ID}" > "${STATUS_JSON_FILE}"; then
    status="$(jq -r '.instance.status // ""' "${STATUS_JSON_FILE}")"
    ip="$(jq -r '.instance.main_ip // ""' "${STATUS_JSON_FILE}")"
    if [[ "${status}" == "active" && -n "${ip}" && "${ip}" != "null" ]]; then
      INSTANCE_IP="${ip}"
      break
    fi
  fi
  sleep 5
done

if [[ -z "${INSTANCE_IP}" ]]; then
  echo "Instance became visible but never reported active with an IPv4" >&2
  exit 1
fi

PORTS_FILE="${RUN_DIR}/ports.txt"
jq -r '[22, .port, .ssPort, .hysteriaPort, .vlessPort, .trojanPort] | map(select(. != null and . != 0)) | unique[]' \
  "${NODE_JSON_FILE}" > "${PORTS_FILE}"

PORT_RESULTS_FILE="${RUN_DIR}/port-results.txt"
: > "${PORT_RESULTS_FILE}"
port_attempts=$(( TIMEOUT_PORT_SEC / 5 ))
if (( port_attempts < 1 )); then
  port_attempts=1
fi

while IFS= read -r port; do
  [[ -z "${port}" ]] && continue
  ok="0"
  for _ in $(seq 1 "${port_attempts}"); do
    if timeout 3 bash -lc "</dev/tcp/${INSTANCE_IP}/${port}" 2>/dev/null; then
      ok="1"
      break
    fi
    sleep 5
  done
  if [[ "${ok}" == "1" ]]; then
    echo "${port} OPEN" >> "${PORT_RESULTS_FILE}"
  else
    echo "${port} CLOSED" >> "${PORT_RESULTS_FILE}"
    echo "Port ${port} did not open on ${INSTANCE_IP}" >&2
    exit 1
  fi
done < "${PORTS_FILE}"

destroy_instance

SUMMARY_JSON="${RUN_DIR}/summary.json"
export SUMMARY_JSON RUN_DIR INSTANCE_ID INSTANCE_LABEL INSTANCE_IP INSTANCE_REGION INSTANCE_PLAN DESTROYED PROXY_SNAPSHOT_SUPPORTED
python3 - <<'PY'
import json
import os

summary = {
    "instanceId": os.environ["INSTANCE_ID"],
    "label": os.environ["INSTANCE_LABEL"],
    "ipv4": os.environ["INSTANCE_IP"],
    "region": os.environ["INSTANCE_REGION"],
    "plan": os.environ["INSTANCE_PLAN"],
    "destroyed": os.environ["DESTROYED"] == "1",
    "artifactsDir": os.environ["RUN_DIR"],
    "proxySnapshotSupported": os.environ["PROXY_SNAPSHOT_SUPPORTED"] == "1",
}

with open(os.environ["SUMMARY_JSON"], "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
PY

cat > "${RUN_DIR}/summary.txt" <<EOF
Local GUI Vultr smoke passed.
Artifacts: ${RUN_DIR}
Instance ID: ${INSTANCE_ID}
Label: ${INSTANCE_LABEL}
IPv4: ${INSTANCE_IP}
Region: ${INSTANCE_REGION}
Plan: ${INSTANCE_PLAN}
Destroyed: ${DESTROYED}
EOF

echo "Local GUI Vultr smoke passed."
echo "Artifacts: ${RUN_DIR}"
echo "Instance ID: ${INSTANCE_ID}"
echo "Label: ${INSTANCE_LABEL}"
echo "IPv4: ${INSTANCE_IP}"
echo "Region: ${INSTANCE_REGION}"
echo "Plan: ${INSTANCE_PLAN}"
