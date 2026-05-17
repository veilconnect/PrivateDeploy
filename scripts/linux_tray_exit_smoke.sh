#!/usr/bin/env bash
set -euo pipefail

APP_BIN="${APP_BIN:-/usr/bin/privatedeploy}"
WINDOW_PATTERN="${WINDOW_PATTERN:-PrivateDeploy}"
WINDOW_WAIT_SEC="${WINDOW_WAIT_SEC:-30}"
EXIT_WAIT_SEC="${EXIT_WAIT_SEC:-20}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in awk gdbus grep pgrep sed wmctrl xdotool; do
  require_cmd "${cmd}"
done

if [[ ! -x "${APP_BIN}" ]]; then
  echo "App binary not found or not executable: ${APP_BIN}" >&2
  exit 1
fi

window_ids() {
  xdotool search --name "${WINDOW_PATTERN}" 2>/dev/null || true
}

process_list() {
  pgrep -af 'PrivateDeploy|/usr/bin/privatedeploy|/usr/lib/privatedeploy/privatedeploy|privatedeploy-tray|sing-box' || true
}

wait_for_window() {
  local id=""
  for _ in $(seq 1 "${WINDOW_WAIT_SEC}"); do
    id="$(window_ids | head -n1)"
    if [[ -n "${id}" ]]; then
      printf '%s\n' "${id}"
      return 0
    fi
    sleep 1
  done
  return 1
}

tray_service_for_pid() {
  local tray_pid="$1"
  local registered
  registered="$(
    gdbus call --session \
      --dest org.kde.StatusNotifierWatcher \
      --object-path /StatusNotifierWatcher \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems
  )"
  printf '%s\n' "${registered}" | grep -oE "org\.kde\.StatusNotifierItem-${tray_pid}-[0-9]+" | head -n1
}

tray_exit_id() {
  local service="$1"
  local layout
  layout="$(
    gdbus call --session \
      --dest "${service}" \
      --object-path /StatusNotifierMenu \
      --method com.canonical.dbusmenu.GetLayout 0 -1 '[]'
  )"
  printf '%s\n' "${layout}" |
    grep -oE "\(int32 [0-9]+, \{'label': <'[^']*'" |
    grep -Eiv "Show|Restart|显示|重启" |
    grep -Ei "Exit|Quit|退出" |
    sed -E "s/^\(int32 ([0-9]+).*/\1/" |
    tail -n1
}

echo "Starting ${APP_BIN}"
"${APP_BIN}" >/tmp/privatedeploy-linux-tray-smoke.out 2>/tmp/privatedeploy-linux-tray-smoke.err &
app_pid="$!"

if ! window_id="$(wait_for_window)"; then
  echo "Window not found within ${WINDOW_WAIT_SEC}s" >&2
  process_list >&2
  exit 1
fi
echo "Window found: ${window_id}"

echo "Closing window to tray"
xdotool windowclose "${window_id}"
sleep 3

if [[ -n "$(window_ids | head -n1)" ]]; then
  echo "Window is still visible after close-to-tray" >&2
  process_list >&2
  exit 1
fi

if ! kill -0 "${app_pid}" 2>/dev/null && ! process_list | grep -Eq 'PrivateDeploy|privatedeploy'; then
  echo "App exited instead of staying in tray" >&2
  exit 1
fi
echo "Close-to-tray ok"

tray_pid="$(pgrep -f 'privatedeploy-tray' | head -n1 || true)"
if [[ -z "${tray_pid}" ]]; then
  echo "privatedeploy-tray process not found" >&2
  process_list >&2
  exit 1
fi

service="$(tray_service_for_pid "${tray_pid}")"
if [[ -z "${service}" ]]; then
  echo "StatusNotifier service not found for tray pid ${tray_pid}" >&2
  exit 1
fi

exit_id="$(tray_exit_id "${service}")"
if [[ -z "${exit_id}" ]]; then
  echo "Exit menu item not found for ${service}" >&2
  exit 1
fi

echo "Triggering tray Exit through DBus: service=${service} id=${exit_id}"
gdbus call --session \
  --dest "${service}" \
  --object-path /StatusNotifierMenu \
  --method com.canonical.dbusmenu.Event \
  "${exit_id}" clicked '<int32 0>' 0 >/dev/null

for _ in $(seq 1 "${EXIT_WAIT_SEC}"); do
  if ! process_list | grep -Eq 'PrivateDeploy|/usr/bin/privatedeploy|/usr/lib/privatedeploy/privatedeploy|privatedeploy-tray|sing-box'; then
    echo "Tray Exit ok"
    exit 0
  fi
  sleep 1
done

echo "Processes still running after tray Exit" >&2
process_list >&2
exit 1
