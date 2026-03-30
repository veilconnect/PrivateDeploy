#!/usr/bin/env bash
set -euo pipefail

APP_BASE="${APP_BASE:?APP_BASE is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
APP_BIN="${APP_BIN:-${APP_BASE}/PrivateDeploy}"
SCALES="${SCALES:-100 125 150}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1600}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1000}"
WINDOW_WAIT_SEC="${WINDOW_WAIT_SEC:-45}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in Xvfb dbus-run-session xdotool xwininfo import convert timeout grep awk; do
  require_cmd "${cmd}"
done

if [[ ! -x "${APP_BIN}" ]]; then
  echo "App binary not found or not executable: ${APP_BIN}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
: > "${SUMMARY_FILE}"

scale_to_env() {
  local scale="$1"
  local gdk_scale="1"
  local dpi_scale

  if (( scale >= 200 )) && (( scale % 100 == 0 )); then
    gdk_scale="$(( scale / 100 ))"
    dpi_scale="1"
  else
    dpi_scale="$(awk "BEGIN { printf \"%.2f\", ${scale} / 100 }")"
  fi

  printf '%s %s\n' "${gdk_scale}" "${dpi_scale}"
}

run_scale() {
  local scale="$1"
  local scale_dir="${OUTPUT_DIR}/scale${scale}"
  local xvfb_pid=""
  local app_pid=""
  local window_id=""
  mkdir -p "${scale_dir}"

  read -r gdk_scale dpi_scale < <(scale_to_env "${scale}")

  cleanup() {
    if [[ -n "${app_pid}" ]]; then
      kill "${app_pid}" >/dev/null 2>&1 || true
      wait "${app_pid}" 2>/dev/null || true
    fi
    if [[ -n "${xvfb_pid}" ]]; then
      kill "${xvfb_pid}" >/dev/null 2>&1 || true
      wait "${xvfb_pid}" 2>/dev/null || true
    fi
  }
  trap cleanup RETURN

  Xvfb ":99" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x24" > "${scale_dir}/xvfb.log" 2>&1 &
  xvfb_pid="$!"
  export DISPLAY=":99"
  sleep 1

  export HOME="${APP_BASE}/home"
  export XDG_CONFIG_HOME="${APP_BASE}/xdg/config"
  export XDG_CACHE_HOME="${APP_BASE}/xdg/cache"
  export XDG_DATA_HOME="${APP_BASE}/xdg/data"
  export XDG_RUNTIME_DIR="${APP_BASE}/xdg/runtime"
  export PRIVATEDEPLOY_SECRET_STORE_DIR="${APP_BASE}/secrets"
  export PRIVATEDEPLOY_DISABLE_TRAY="1"
  export PRIVATEDEPLOY_LINUX_MINIMAL_SHELL="1"
  export GDK_BACKEND="x11"
  export LIBGL_ALWAYS_SOFTWARE="1"
  export GDK_SCALE="${gdk_scale}"
  export GDK_DPI_SCALE="${dpi_scale}"
  export USER="${HOST_USER:-user}"
  export LOGNAME="${HOST_USER:-user}"
  export NO_AT_BRIDGE="1"
  export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS="${WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS:-1}"

  mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}" "${XDG_RUNTIME_DIR}" "${PRIVATEDEPLOY_SECRET_STORE_DIR}"
  chmod 700 "${XDG_RUNTIME_DIR}"

  dbus-run-session -- "${APP_BIN}" > "${scale_dir}/app.out" 2> "${scale_dir}/app.err" &
  app_pid="$!"

  for _ in $(seq 1 "${WINDOW_WAIT_SEC}"); do
    window_id="$(xdotool search --onlyvisible --name "PrivateDeploy" 2>/dev/null | head -n1 || true)"
    if [[ -n "${window_id}" ]]; then
      break
    fi
    if ! kill -0 "${app_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [[ -z "${window_id}" ]]; then
    echo "scale=${scale} status=FAIL reason=no-window" | tee -a "${SUMMARY_FILE}"
    return 1
  fi

  sleep 6
  import -window root "${scale_dir}/root.png"
  import -window "${window_id}" "${scale_dir}/window.png"

  local color_count
  color_count="$(convert "${scale_dir}/window.png" -format "%k" info: 2>/dev/null || echo 0)"
  local cloud_loaded="0"
  if grep -Eq 'ListCloud(Instances|Regions|Plans)Typed' "${scale_dir}/app.err"; then
    cloud_loaded="1"
  fi

  if [[ "${color_count}" =~ ^[0-9]+$ ]] && (( color_count > 1 )); then
    echo "scale=${scale} status=PASS colors=${color_count} cloudLoaded=${cloud_loaded}" | tee -a "${SUMMARY_FILE}"
    return 0
  fi

  echo "scale=${scale} status=FAIL reason=blank-window colors=${color_count} cloudLoaded=${cloud_loaded}" | tee -a "${SUMMARY_FILE}"
  return 1
}

overall_status=0
for scale in ${SCALES}; do
  if ! run_scale "${scale}"; then
    overall_status=1
  fi
done

exit "${overall_status}"
