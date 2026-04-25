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
WORKBENCH_DEPLOY_X="${WORKBENCH_DEPLOY_X:-522}"
WORKBENCH_DEPLOY_Y="${WORKBENCH_DEPLOY_Y:-245}"
CREATE_DEPLOY_X="${CREATE_DEPLOY_X:-220}"
CREATE_DEPLOY_Y="${CREATE_DEPLOY_Y:-352}"
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

for cmd in jq curl xdotool xwininfo import xvfb-run python3 timeout tesseract dbus-run-session openbox; do
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
  exec xvfb-run -a dbus-run-session env PD_GUI_SMOKE_IN_XVFB=1 "$0" "$@"
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
OPENBOX_PID=""

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
  if [[ -n "${OPENBOX_PID}" ]]; then
    kill "${OPENBOX_PID}" >/dev/null 2>&1 || true
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

ocr_word_hits() {
  local image_path="$1"
  local word="$2"
  local json_out="$3"
  python3 - "${image_path}" "${word}" "${json_out}" <<'PY'
import json
import subprocess
import sys

image_path, word, json_out = sys.argv[1:4]
result = subprocess.run(
    ["tesseract", image_path, "stdout", "--psm", "11", "tsv"],
    text=True,
    capture_output=True,
    check=False,
)
hits = []
for line in result.stdout.splitlines()[1:]:
    parts = line.split("\t")
    if len(parts) != 12:
        continue
    text = parts[11].strip()
    if text.lower() != word.lower():
        continue
    try:
        left = int(parts[6])
        top = int(parts[7])
        width = int(parts[8])
        height = int(parts[9])
        conf = int(float(parts[10]))
    except Exception:
        continue
    hits.append(
        {
            "left": left,
            "top": top,
            "width": width,
            "height": height,
            "center_x": left + width // 2,
            "center_y": top + height // 2,
            "conf": conf,
            "text": text,
        }
    )
with open(json_out, "w", encoding="utf-8") as f:
    json.dump(hits, f, indent=2)
PY
}

ocr_contains_text() {
  local image_path="$1"
  local pattern="$2"
  tesseract "${image_path}" stdout --psm 6 2>/dev/null | grep -Eiq "${pattern}"
}

pick_hit_center() {
  local json_path="$1"
  local mode="$2"
  python3 - "${json_path}" "${mode}" <<'PY'
import json
import sys

json_path, mode = sys.argv[1:3]
with open(json_path, "r", encoding="utf-8") as f:
    hits = json.load(f)
if not hits:
    sys.exit(1)
if mode == "top":
    pick = sorted(hits, key=lambda item: item["top"])[0]
elif mode == "bottom-over-250":
    filtered = [item for item in hits if item["top"] > 250]
    if not filtered:
        sys.exit(2)
    pick = sorted(filtered, key=lambda item: item["top"])[-1]
elif mode == "top-over-250":
    filtered = [item for item in hits if item["top"] > 250]
    if not filtered:
        sys.exit(4)
    pick = sorted(filtered, key=lambda item: item["top"])[0]
else:
    sys.exit(3)
print(f'{pick["center_x"]} {pick["center_y"]}')
PY
}

window_origin() {
  xwininfo -id "${WINDOW_ID}" | awk '/Absolute upper-left X:/ {x=$4} /Absolute upper-left Y:/ {y=$4} END { print x, y }'
}

capture_window_crop() {
  local root_image="$1"
  local crop_image="$2"
  local geometry
  geometry="$(xwininfo -id "${WINDOW_ID}" | awk '
    /Absolute upper-left X:/ { x = $4 }
    /Absolute upper-left Y:/ { y = $4 }
    /Width:/ { w = $2 }
    /Height:/ { h = $2 }
    END { print x, y, w, h }
  ')"
  local x y w h
  read -r x y w h <<<"${geometry}"
  if [[ -z "${x:-}" || -z "${y:-}" || -z "${w:-}" || -z "${h:-}" ]]; then
    return 1
  fi
  convert "${root_image}" -crop "${w}x${h}+${x}+${y}" +repage "${crop_image}"
}

click_absolute() {
  local abs_x="$1"
  local abs_y="$2"
  xdotool windowactivate --sync "${WINDOW_ID}"
  xdotool mousemove --sync "${abs_x}" "${abs_y}"
  sleep 0.1
  xdotool mousedown 1
  sleep 0.05
  xdotool mouseup 1
}

deploy_click_logged() {
  grep -q "\[CloudView\] handleDeploy invoked" "${RUN_DIR}/app.err" || \
    grep -q "CreateCloudInstanceTyped called" "${RUN_DIR}/app.err"
}

fetch_live_instance_ids() {
  local out_file="$1"
  vultr_request GET "/instances" | jq -r '.instances[].id' | sort -u > "${out_file}"
}

echo "Artifacts: ${RUN_DIR}"
echo "App base:   ${APP_BASE}"

snapshot_proxy "${RUN_DIR}/proxy.before"

mkdir -p "${APP_BASE}/data/cloud" "${APP_BASE}/secrets"
cp "${APP_BIN}" "${APP_BASE}/PrivateDeploy"
chmod +x "${APP_BASE}/PrivateDeploy"

cat > "${APP_BASE}/data/user.yaml" <<'YAML'
width: 800
height: 840
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
    "extra": {"portProfile": "edge443"},
}

path = os.path.join(base, "data", "cloud", "vultr-config.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
PY

export PRIVATEDEPLOY_SECRET_STORE_DIR="${APP_BASE}/secrets"
export GDK_BACKEND="x11"
export LIBGL_ALWAYS_SOFTWARE="1"

openbox > "${RUN_DIR}/openbox.log" 2>&1 &
OPENBOX_PID=$!
sleep 2

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
capture_window_crop "${RUN_DIR}/workbench.png" "${RUN_DIR}/workbench-crop.png"
ocr_word_hits "${RUN_DIR}/workbench.png" "Deploy" "${RUN_DIR}/workbench-ocr.json"
WORKBENCH_COORDS="$(pick_hit_center "${RUN_DIR}/workbench-ocr.json" top || true)"
if [[ -z "${WORKBENCH_COORDS}" ]]; then
  echo "Failed to locate Deploy button in ${RUN_DIR}/workbench.png" >&2
  exit 1
fi
WORKBENCH_DEPLOY_X="${WORKBENCH_COORDS%% *}"
WORKBENCH_DEPLOY_Y="${WORKBENCH_COORDS##* }"

BASELINE_IDS_FILE="${RUN_DIR}/baseline-instance-ids.txt"
fetch_live_instance_ids "${BASELINE_IDS_FILE}"

DEPLOY_PAGE_READY="0"
NAV_ATTEMPTS_FILE="${RUN_DIR}/nav-attempts.txt"
: > "${NAV_ATTEMPTS_FILE}"
while IFS= read -r offset; do
  [[ -z "${offset}" ]] && continue
  offset_x="${offset%% *}"
  offset_y="${offset##* }"
  target_x=$(( WORKBENCH_DEPLOY_X + offset_x ))
  target_y=$(( WORKBENCH_DEPLOY_Y + offset_y ))
  printf '%s %s -> %s %s\n' "${offset_x}" "${offset_y}" "${target_x}" "${target_y}" >> "${NAV_ATTEMPTS_FILE}"
  click_absolute "${target_x}" "${target_y}"
  sleep 2
  import -window root "${RUN_DIR}/cloud.png"
  import -window "${WINDOW_ID}" "${RUN_DIR}/cloud-window.png"
  capture_window_crop "${RUN_DIR}/cloud.png" "${RUN_DIR}/cloud-crop.png"
  if ocr_contains_text "${RUN_DIR}/cloud.png" 'Provider|Settings'; then
    DEPLOY_PAGE_READY="1"
    break
  fi
done <<'EOF'
0 0
-28 0
28 0
0 -10
0 10
-20 -8
20 -8
EOF

if [[ "${DEPLOY_PAGE_READY}" != "1" ]]; then
  echo "Failed to open Deploy Node page from Workbench" >&2
  exit 1
fi

if grep -q "TestAllCloudRegions called" "${RUN_DIR}/app.err"; then
  for _ in $(seq 1 30); do
    if grep -q "Latency test completed for all regions" "${RUN_DIR}/app.err"; then
      break
    fi
    sleep 1
  done
fi
ocr_word_hits "${RUN_DIR}/cloud.png" "Deploy" "${RUN_DIR}/cloud-ocr.json"
CREATE_COORDS="$(pick_hit_center "${RUN_DIR}/cloud-ocr.json" bottom-over-250 || true)"
if [[ -z "${CREATE_COORDS}" ]]; then
  echo "Failed to locate Create Route button in ${RUN_DIR}/cloud.png" >&2
  exit 1
fi
CREATE_DEPLOY_X="${CREATE_COORDS%% *}"
CREATE_DEPLOY_Y="${CREATE_COORDS##* }"

CLICK_ATTEMPTS_FILE="${RUN_DIR}/click-attempts.txt"
: > "${CLICK_ATTEMPTS_FILE}"
DEPLOY_TRIGGERED="0"
while IFS= read -r offset; do
  [[ -z "${offset}" ]] && continue
  offset_x="${offset%% *}"
  offset_y="${offset##* }"
  target_x=$(( CREATE_DEPLOY_X + offset_x ))
  target_y=$(( CREATE_DEPLOY_Y + offset_y ))
  printf '%s %s -> %s %s\n' "${offset_x}" "${offset_y}" "${target_x}" "${target_y}" >> "${CLICK_ATTEMPTS_FILE}"
  click_absolute "${target_x}" "${target_y}"
  sleep 1
  if deploy_click_logged; then
    DEPLOY_TRIGGERED="1"
    break
  fi
done <<'EOF'
0 0
-32 0
-16 0
16 0
32 0
0 -12
0 12
-24 -8
24 -8
EOF

if [[ "${DEPLOY_TRIGGERED}" != "1" ]] && ! deploy_click_logged; then
  KEYBOARD_ATTEMPTS_FILE="${RUN_DIR}/keyboard-attempts.txt"
  : > "${KEYBOARD_ATTEMPTS_FILE}"
  focus_x=$(( CREATE_DEPLOY_X - 120 ))
  focus_y=$(( CREATE_DEPLOY_Y - 36 ))
  click_absolute "${focus_x}" "${focus_y}"
  sleep 0.5
  for attempt in $(seq 1 10); do
    printf 'tab-%s\n' "${attempt}" >> "${KEYBOARD_ATTEMPTS_FILE}"
    xdotool windowactivate --sync "${WINDOW_ID}"
    xdotool key Tab
    sleep 0.15
    xdotool key Return
    sleep 1
    if deploy_click_logged; then
      DEPLOY_TRIGGERED="1"
      break
    fi
  done
fi

sleep 3
import -window root "${RUN_DIR}/after-create.png"
import -window "${WINDOW_ID}" "${RUN_DIR}/after-create-window.png"
capture_window_crop "${RUN_DIR}/after-create.png" "${RUN_DIR}/after-create-crop.png"
ocr_word_hits "${RUN_DIR}/after-create.png" "Deploy" "${RUN_DIR}/after-create-ocr.json"

if [[ "${DEPLOY_TRIGGERED}" != "1" ]] && ! deploy_click_logged; then
  echo "Failed to trigger Create & Deploy button click" >&2
  exit 1
fi

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
  CURRENT_IDS_FILE="${RUN_DIR}/current-instance-ids.txt"
  fetch_live_instance_ids "${CURRENT_IDS_FILE}"
  while IFS= read -r candidate; do
    [[ -z "${candidate}" ]] && continue
    if ! grep -qx "${candidate}" "${BASELINE_IDS_FILE}"; then
      echo "${candidate}" > "${NEW_ID_FILE}"
      break 2
    fi
  done < "${CURRENT_IDS_FILE}"
  sleep 5
done

INSTANCE_ID="$(tr -d '\r\n' < "${NEW_ID_FILE}")"
if [[ -z "${INSTANCE_ID}" ]]; then
  echo "Failed to detect new instance via live Vultr API" >&2
  exit 1
fi

STATUS_JSON_FILE="${RUN_DIR}/instance-status.json"
for _ in $(seq 1 "${create_attempts}"); do
  if vultr_request GET "/instances/${INSTANCE_ID}" > "${STATUS_JSON_FILE}"; then
    status="$(jq -r '.instance.status // ""' "${STATUS_JSON_FILE}")"
    ip="$(jq -r '.instance.main_ip // ""' "${STATUS_JSON_FILE}")"
    if [[ "${status}" == "active" && -n "${ip}" && "${ip}" != "null" ]]; then
      INSTANCE_IP="${ip}"
      INSTANCE_LABEL="$(jq -r '.instance.label // ""' "${STATUS_JSON_FILE}")"
      INSTANCE_REGION="$(jq -r '.instance.region // ""' "${STATUS_JSON_FILE}")"
      INSTANCE_PLAN="$(jq -r '.instance.plan // ""' "${STATUS_JSON_FILE}")"
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
printf '22\n24443\n8443\n443\n' > "${PORTS_FILE}"

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
