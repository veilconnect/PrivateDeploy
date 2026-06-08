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
  xdotool search --onlyvisible --name "${WINDOW_PATTERN}" 2>/dev/null || true
}

process_list() {
  ps -eo pid=,comm=,args= |
    awk '$2 == "PrivateDeploy" || $2 == "privatedeploy" || $2 == "privatedeploy-t" || $2 == "privatedeploy-tray" || $2 == "sing-box"'
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

registered_status_items() {
  local registered
  registered="$(
    gdbus call --session \
      --dest org.kde.StatusNotifierWatcher \
      --object-path /StatusNotifierWatcher \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems
  )"
  printf '%s\n' "${registered}" |
    grep -oE "(:[0-9]+\.[0-9]+|[A-Za-z0-9_.-]+)(/[^'\",>]*)"
}

tray_item() {
  local item service path title menu
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    service="${item%%/*}"
    path="/${item#*/}"
    title="$(
      gdbus call --session \
        --dest "${service}" \
        --object-path "${path}" \
        --method org.freedesktop.DBus.Properties.Get \
        org.kde.StatusNotifierItem Title 2>/dev/null || true
    )"
    if [[ "${title}" != *PrivateDeploy* ]]; then
      continue
    fi
    menu="$(
      gdbus call --session \
        --dest "${service}" \
        --object-path "${path}" \
        --method org.freedesktop.DBus.Properties.Get \
        org.kde.StatusNotifierItem Menu 2>/dev/null |
        grep -oE "'/[^']+'" |
        tr -d "'" || true
    )"
    if [[ -n "${menu}" ]]; then
      printf '%s %s\n' "${service}" "${menu}"
      return 0
    fi
  done < <(registered_status_items || true)
  return 1
}

tray_exit_id() {
  local service="$1"
  local menu_path="${2:-/StatusNotifierMenu}"
  local layout
  layout="$(
    gdbus call --session \
      --dest "${service}" \
      --object-path "${menu_path}" \
      --method com.canonical.dbusmenu.GetLayout -- 0 -1 '[]'
  )"
  printf '%s\n' "${layout}" |
    grep -oE "<?\((int32 )?[0-9]+, \{[^}]*'label': <'[^']*'[^}]*\}" |
    grep -Eiv "Show|Restart|显示|重启" |
    grep -Ei "Exit|Quit|退出" |
    sed -E "s/^<?\((int32 )?([0-9]+),.*/\2/" |
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
sleep 6

if [[ -n "$(window_ids | head -n1)" ]]; then
  echo "Window is still visible after close-to-tray" >&2
  process_list >&2
  exit 1
fi

if ! kill -0 "${app_pid}" 2>/dev/null && [[ -z "$(process_list)" ]]; then
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

tray_info="$(tray_item || true)"
if [[ -z "${tray_info}" ]]; then
  echo "StatusNotifier service not found for PrivateDeploy tray pid ${tray_pid}" >&2
  exit 1
fi
read -r service menu_path <<<"${tray_info}"

exit_id="$(tray_exit_id "${service}" "${menu_path}" || true)"
if [[ -z "${exit_id}" ]]; then
  echo "Exit menu item not found for ${service}" >&2
  exit 1
fi

echo "Triggering tray Exit through DBus: service=${service} menu=${menu_path} id=${exit_id}"
gdbus call --session \
  --dest "${service}" \
  --object-path "${menu_path}" \
  --method com.canonical.dbusmenu.Event \
  "${exit_id}" clicked '<int32 0>' 0 >/dev/null

for _ in $(seq 1 "${EXIT_WAIT_SEC}"); do
  if [[ -z "$(process_list)" ]]; then
    echo "Tray Exit ok"
    exit 0
  fi
  sleep 1
done

echo "Processes still running after tray Exit" >&2
process_list >&2
exit 1
