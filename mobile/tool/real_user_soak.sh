#!/bin/bash
# Real-user soak test for a single Android device without clearing app data.
# Usage: VULTR_API_KEY=... real_user_soak.sh <device_serial> <output_dir> [duration_minutes]

set -euo pipefail

DEVICE="${1:?usage: real_user_soak.sh <device_serial> <output_dir> [duration_minutes]}"
OUTDIR="${2:?usage: real_user_soak.sh <device_serial> <output_dir> [duration_minutes]}"
DURATION_MINUTES="${3:-30}"

PKG="com.privatedeploy.mobile"
ACTIVITY="$PKG/.MainActivity"
UI_XML="/sdcard/ui.xml"
RUN_LOG="$OUTDIR/run.log"
RESULTS="$OUTDIR/results.txt"

VULTR_API_KEY="${VULTR_API_KEY:-}"
if [ -z "$VULTR_API_KEY" ]; then
  echo "VULTR_API_KEY is required" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
: > "$RUN_LOG"
: > "$RESULTS"

WORKSPACE_PATTERN='content-desc="(Workspace|工作区)"|text="(Workspace|工作区)"'
CONNECT_PATTERN='content-desc="(Connect|连接)"|text="(Connect|连接)"'
DISCONNECT_PATTERN='content-desc="(Disconnect|断开)"|text="(Disconnect|断开)"'
CONNECTED_PATTERN='content-desc="(Connected|已连接)"|text="(Connected|已连接)"'
CONNECTING_PATTERN='content-desc="(Connecting\.\.\.|连接中\.\.\.)"|text="(Connecting\.\.\.|连接中\.\.\.)"'
RESTART_PATTERN='content-desc="(Restart VPN|重启 VPN)"|text="(Restart VPN|重启 VPN)"'
SETTINGS_PATTERN='content-desc="(Settings|设置)"|text="(Settings|设置)"'
CLOUD_API_KEY_PATTERN='content-desc="(Cloud API Key|云端 API Key|Set API Key|设置 API Key)"|text="(Cloud API Key|云端 API Key|Set API Key|设置 API Key)"'
VERIFY_SAVE_PATTERN='content-desc="(Verify (&amp;|&) Save|验证并保存)"|text="(Verify (&amp;|&) Save|验证并保存)"'
CANCEL_PATTERN='content-desc="(Cancel|取消)"|text="(Cancel|取消)"'
API_KEY_DIALOG_TITLE_PATTERN='content-desc="(API Key|云端 API Key)"|text="(API Key|云端 API Key)"'
API_KEY_SUCCESS_PATTERN='content-desc="(API key saved and verified|API Key 已保存并验证通过)"|text="(API key saved and verified|API Key 已保存并验证通过)"'
API_KEY_FAILURE_PATTERN='content-desc="(Failed to save API key|Invalid API token|invalid api key|验证失败|保存 API Key 失败)"|text="(Failed to save API key|Invalid API token|invalid api key|验证失败|保存 API Key 失败)"'
CLOUD_NOT_CONFIGURED_PATTERN='content-desc="(Cloud access not configured|云端访问未配置)"|text="(Cloud access not configured|云端访问未配置)"'
DEPLOY_NODE_PATTERN='content-desc="(Deploy [Nn]ode|Deploy cloud node|部署云节点)"|text="(Deploy [Nn]ode|Deploy cloud node|部署云节点)"'
NO_CLOUD_NODES_PATTERN='content-desc="(No cloud nodes yet|暂无云节点)"|text="(No cloud nodes yet|暂无云节点)"'
VPN_DIALOG_TITLE_PATTERN='text="(Connection request|连接请求|VPN connection request|VPN 连接请求)"|content-desc="(Connection request|连接请求|VPN connection request|VPN 连接请求)"'
VPN_DIALOG_ALLOW_PATTERN='resource-id="android:id/button1"|text="(OK|确定|允许|Allow|继续)"|content-desc="(OK|确定|允许|Allow|继续)"'
CHROME_ACCEPT_PATTERN='text="(Accept & continue|接受并继续)"|content-desc="(Accept & continue|接受并继续)"'
CHROME_NO_THANKS_PATTERN='text="(No thanks|不用了|跳过|暂不)"|content-desc="(No thanks|不用了|跳过|暂不)"'
CHROME_USE_WITHOUT_ACCOUNT_PATTERN='text="(Use without an account|不登录使用)"|content-desc="(Use without an account|不登录使用)"'
CHROME_GOT_IT_PATTERN='text="(Got it|知道了)"|content-desc="(Got it|知道了)"'

WEBSITES=(
  "https://example.com/|example|Example|example\\.com"
  "https://www.wikipedia.org/|wikipedia|Wikipedia|wikipedia\\.org"
  "https://github.com/|github|GitHub|github\\.com"
  "https://openai.com/|openai|OpenAI|openai\\.com"
  "https://www.cloudflare.com/|cloudflare|Cloudflare|cloudflare\\.com"
)

log() {
  local msg="$1"
  printf '[%s] %s\n' "$DEVICE" "$msg" | tee -a "$RUN_LOG"
}

record_kv() {
  printf '%s=%s\n' "$1" "$2" >> "$RESULTS"
}

screenshot() {
  adb -s "$DEVICE" exec-out screencap -p > "$OUTDIR/$1.png" 2>/dev/null || true
}

tap() {
  adb -s "$DEVICE" shell input tap "$1" "$2" >/dev/null 2>&1 || true
}

swipe() {
  adb -s "$DEVICE" shell input swipe "$1" "$2" "$3" "$4" "${5:-350}" >/dev/null 2>&1 || true
}

press_back() {
  adb -s "$DEVICE" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
}

press_home() {
  adb -s "$DEVICE" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
}

unlock_device() {
  adb -s "$DEVICE" shell svc power stayon true >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell cmd statusbar collapse >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell input swipe 540 1900 540 500 180 >/dev/null 2>&1 || true
  sleep 1
  adb -s "$DEVICE" shell cmd statusbar collapse >/dev/null 2>&1 || true
}

dump_ui() {
  adb -s "$DEVICE" shell uiautomator dump "$UI_XML" >/dev/null 2>&1
  adb -s "$DEVICE" shell cat "$UI_XML" 2>/dev/null || true
}

bounds_center() {
  echo "$1" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \2 \3 \4/' | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'
}

find_bounds() {
  local pattern="$1"
  dump_ui | tr '>' '\n' | grep -E "$pattern" | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1
}

find_nth_bounds() {
  local pattern="$1"
  local index="${2:-1}"
  dump_ui | tr '>' '\n' | grep -E "$pattern" | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | sed -n "${index}p"
}

ui_contains() {
  local pattern="$1"
  dump_ui | grep -Eq "$pattern"
}

wait_for_bounds() {
  local pattern="$1"
  local attempts="${2:-15}"
  local delay="${3:-1}"
  local bounds=""
  local i=0
  for ((i = 0; i < attempts; i++)); do
    bounds=$(find_bounds "$pattern" || true)
    if [ -n "$bounds" ]; then
      echo "$bounds"
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

tap_bounds() {
  local bounds="$1"
  local center
  center=$(bounds_center "$bounds")
  tap "$(echo "$center" | awk '{print $1}')" "$(echo "$center" | awk '{print $2}')"
}

clear_text_field() {
  local bounds="$1"
  tap_bounds "$bounds"
  sleep 1
  local i=0
  adb -s "$DEVICE" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || true
  sleep 1
  for ((i = 0; i < 64; i++)); do
    adb -s "$DEVICE" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || true
  done
  adb -s "$DEVICE" shell input keyevent KEYCODE_MOVE_HOME >/dev/null 2>&1 || true
  sleep 1
  for ((i = 0; i < 64; i++)); do
    adb -s "$DEVICE" shell input keyevent KEYCODE_FORWARD_DEL >/dev/null 2>&1 || true
  done
  sleep 1
}

enter_text_at_bounds() {
  local bounds="$1"
  local text="$2"
  tap_bounds "$bounds"
  sleep 1
  adb -s "$DEVICE" shell input text "$text" >/dev/null 2>&1 || true
  sleep 1
}

app_pid() {
  adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r'
}

current_focus() {
  adb -s "$DEVICE" shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' || true
}

app_is_foreground() {
  current_focus | grep -q "$ACTIVITY"
}

app_is_running() {
  [ -n "$(app_pid)" ]
}

vpn_transport_active() {
  adb -s "$DEVICE" shell dumpsys connectivity 2>/dev/null | grep -q 'Transports: VPN'
}

vpn_iface_up() {
  adb -s "$DEVICE" shell ip addr show 2>/dev/null | grep -Eq '^[0-9]+: (tun|ppp|utun)[0-9]*: .*UP'
}

vpn_egress_logged() {
  adb -s "$DEVICE" logcat -d 2>/dev/null | grep -q 'VPN egress probe succeeded via'
}

launch_app_cold() {
  unlock_device
  adb -s "$DEVICE" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 1
  adb -s "$DEVICE" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 1
  unlock_device
}

launch_app_warm() {
  unlock_device
  adb -s "$DEVICE" shell am start -n "$ACTIVITY" >/dev/null 2>&1 || true
  sleep 1
  unlock_device
}

ensure_app_workspace() {
  local attempts="${1:-20}"
  local i=0
  for ((i = 0; i < attempts; i++)); do
    if app_is_foreground && [ -n "$(find_bounds "$WORKSPACE_PATTERN" || true)" ]; then
      return 0
    fi
    launch_app_warm
    sleep 2
  done
  return 1
}

accept_vpn_permission_if_present() {
  local title=""
  local allow=""
  title=$(find_bounds "$VPN_DIALOG_TITLE_PATTERN" || true)
  allow=$(find_bounds "$VPN_DIALOG_ALLOW_PATTERN" || true)
  if [ -n "$title" ] || current_focus | grep -q 'vpndialogs'; then
    if [ -n "$allow" ]; then
      log "VPN permission dialog detected, accepting"
      tap_bounds "$allow"
      sleep 2
      return 0
    fi
  fi
  return 1
}

dismiss_dialog_if_present() {
  local cancel=""
  cancel=$(find_bounds "$CANCEL_PATTERN" || true)
  if [ -n "$cancel" ]; then
    tap_bounds "$cancel"
    sleep 1
    return 0
  fi
  return 1
}

api_key_dialog_visible() {
  [ -n "$(find_bounds "$VERIFY_SAVE_PATTERN" || true)" ] || \
    [ -n "$(find_bounds "$API_KEY_DIALOG_TITLE_PATTERN" || true)" ] || \
    [ -n "$(find_bounds 'class="android.widget.EditText"' || true)" ]
}

cloud_access_ready() {
  if [ -n "$(find_bounds "$CLOUD_NOT_CONFIGURED_PATTERN" || true)" ]; then
    return 1
  fi
  if [ -n "$(find_bounds "$DEPLOY_NODE_PATTERN" || true)" ]; then
    return 0
  fi
  if [ -n "$(find_bounds "$NO_CLOUD_NODES_PATTERN" || true)" ]; then
    return 0
  fi
  dump_ui | grep -q '云节点'
}

wait_for_api_key_save_success() {
  local attempts="${1:-45}"
  local i=0
  for ((i = 0; i < attempts; i++)); do
    sleep 2
    if ! app_is_running; then
      return 1
    fi
    if ui_contains "$API_KEY_SUCCESS_PATTERN"; then
      return 0
    fi
    if ui_contains "$API_KEY_FAILURE_PATTERN"; then
      return 1
    fi
    if ! api_key_dialog_visible && ensure_app_workspace 1 && cloud_access_ready; then
      return 0
    fi
  done
  return 1
}

set_vultr_api_key() {
  ensure_app_workspace 10
  if cloud_access_ready; then
    log "Cloud access already configured, skipping API key re-entry"
    screenshot "02_api_key_already_configured"
    return 0
  fi

  local api_action=""
  local key_field=""
  local save_button=""

  api_action=$(wait_for_bounds "$CLOUD_API_KEY_PATTERN" 10 1 || true)
  if [ -z "$api_action" ]; then
    log "Could not find Cloud API Key action"
    return 1
  fi

  tap_bounds "$api_action"
  sleep 2

  key_field=$(wait_for_bounds 'class="android.widget.EditText"' 10 1 || true)
  save_button=$(wait_for_bounds "$VERIFY_SAVE_PATTERN" 10 1 || true)
  if [ -z "$key_field" ] || [ -z "$save_button" ]; then
    log "Cloud API Key dialog controls not found"
    return 1
  fi

  clear_text_field "$key_field"
  enter_text_at_bounds "$key_field" "$VULTR_API_KEY"
  adb -s "$DEVICE" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  sleep 1
  tap_bounds "$save_button"
  log "Submitted Vultr API key for verification"

  if wait_for_api_key_save_success 45; then
    screenshot "02_api_key_saved"
    return 0
  fi

  screenshot "02_api_key_timeout"
  log "Timed out waiting for API key verification to succeed"
  return 1
}

connect_vpn() {
  ensure_app_workspace 10
  adb -s "$DEVICE" logcat -c >/dev/null 2>&1 || true

  local connect_bounds=""
  connect_bounds=$(wait_for_bounds "$CONNECT_PATTERN" 10 1 || true)
  if [ -z "$connect_bounds" ]; then
    log "Connect button not found"
    return 1
  fi

  tap_bounds "$connect_bounds"
  log "Triggered VPN connect flow"

  local i=0
  for ((i = 0; i < 75; i++)); do
    accept_vpn_permission_if_present || true
    sleep 2

    if ! app_is_running; then
      log "App exited during connect flow"
      return 1
    fi

    if [ -n "$(find_bounds "$DISCONNECT_PATTERN" || true)" ] || \
       [ -n "$(find_bounds "$RESTART_PATTERN" || true)" ] || \
       [ -n "$(find_bounds "$CONNECTED_PATTERN" || true)" ] || \
       vpn_transport_active || vpn_iface_up || vpn_egress_logged; then
      screenshot "03_connected"
      return 0
    fi
  done

  screenshot "03_connect_timeout"
  log "Timed out waiting for VPN to connect"
  return 1
}

disconnect_vpn_if_needed() {
  ensure_app_workspace 6 || true
  local disconnect_bounds=""
  disconnect_bounds=$(find_bounds "$DISCONNECT_PATTERN" || true)
  if [ -n "$disconnect_bounds" ]; then
    tap_bounds "$disconnect_bounds"
    sleep 4
    log "Requested VPN disconnect"
  fi
}

dismiss_chrome_prompts() {
  local bounds=""
  bounds=$(find_bounds "$CHROME_ACCEPT_PATTERN" || true)
  if [ -n "$bounds" ]; then
    tap_bounds "$bounds"
    sleep 2
  fi

  bounds=$(find_bounds "$CHROME_NO_THANKS_PATTERN" || true)
  if [ -n "$bounds" ]; then
    tap_bounds "$bounds"
    sleep 2
  fi

  bounds=$(find_bounds "$CHROME_USE_WITHOUT_ACCOUNT_PATTERN" || true)
  if [ -n "$bounds" ]; then
    tap_bounds "$bounds"
    sleep 2
  fi

  bounds=$(find_bounds "$CHROME_GOT_IT_PATTERN" || true)
  if [ -n "$bounds" ]; then
    tap_bounds "$bounds"
    sleep 2
  fi
}

open_site_in_chrome() {
  local url="$1"
  local label="$2"
  local keyword_regex="$3"
  local visit_id="$4"

  adb -s "$DEVICE" shell am start -n com.android.chrome/com.google.android.apps.chrome.Main -d "$url" >/dev/null 2>&1 || \
    adb -s "$DEVICE" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 || true
  sleep 6
  dismiss_chrome_prompts
  sleep 8

  local page_dump=""
  page_dump=$(dump_ui)
  screenshot "browse_${visit_id}_${label}"

  if echo "$page_dump" | grep -Eiq "$keyword_regex"; then
    log "Visited $label successfully"
    return 0
  fi

  if current_focus | grep -q 'com.android.chrome'; then
    log "Visited $label with weak UI evidence"
    return 0
  fi

  log "Failed to verify $label in Chrome"
  return 1
}

scroll_current_page() {
  swipe 540 1900 540 700 450
  sleep 1
  swipe 540 1800 540 900 450
  sleep 1
}

check_connected_in_app() {
  launch_app_warm
  sleep 3
  ensure_app_workspace 5 || return 1
  screenshot "app_check_$1"
  if [ -n "$(find_bounds "$DISCONNECT_PATTERN" || true)" ] || \
     [ -n "$(find_bounds "$RESTART_PATTERN" || true)" ] || \
     [ -n "$(find_bounds "$CONNECTED_PATTERN" || true)" ] || \
     vpn_transport_active || vpn_iface_up || vpn_egress_logged; then
    return 0
  fi
  return 1
}

ANDROID_VER=$(adb -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
SCREEN=$(adb -s "$DEVICE" shell wm size 2>/dev/null | grep "Physical" | awk '{print $3}')

log "Starting real-user soak on $MODEL Android $ANDROID_VER screen=$SCREEN duration=${DURATION_MINUTES}m"

unlock_device

COLD_START_BEGIN=$(date +%s)
launch_app_cold
if ! ensure_app_workspace 15; then
  screenshot "01_cold_start_fail"
  record_kv "COLD_START" "FAIL"
  record_kv "FAIL_REASON" "workspace_not_visible_after_cold_start"
  exit 1
fi
COLD_START_END=$(date +%s)
COLD_START_SEC=$((COLD_START_END - COLD_START_BEGIN))
screenshot "01_cold_start"
record_kv "COLD_START" "PASS"
record_kv "COLD_START_SECONDS" "$COLD_START_SEC"

if ! set_vultr_api_key; then
  record_kv "API_KEY_SETUP" "FAIL"
  disconnect_vpn_if_needed || true
  exit 1
fi
record_kv "API_KEY_SETUP" "PASS"

if ! connect_vpn; then
  record_kv "VPN_CONNECT" "FAIL"
  disconnect_vpn_if_needed || true
  exit 1
fi
record_kv "VPN_CONNECT" "PASS"

if vpn_egress_logged; then
  EGRESS_LINE=$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep 'VPN egress probe succeeded via' | tail -n 1 | tr -d '\r')
  printf '%s\n' "$EGRESS_LINE" > "$OUTDIR/egress_probe.txt"
  record_kv "VPN_EGRESS_PROBE" "PASS"
else
  record_kv "VPN_EGRESS_PROBE" "UNKNOWN"
fi

START_TS=$(date +%s)
DEADLINE_TS=$((START_TS + DURATION_MINUTES * 60))
VISITS=0
HOT_RESUMES=0
WARM_RESUMES=0
APP_CONNECTED_CHECKS=0
APP_CONNECTED_FAILS=0
BROWSER_VERIFY_FAILS=0

while [ "$(date +%s)" -lt "$DEADLINE_TS" ]; do
  for entry in "${WEBSITES[@]}"; do
    [ "$(date +%s)" -ge "$DEADLINE_TS" ] && break
    IFS='|' read -r url label keyword_regex host_regex <<< "$entry"
    VISITS=$((VISITS + 1))
    if ! open_site_in_chrome "$url" "$label" "$keyword_regex|$host_regex" "$VISITS"; then
      BROWSER_VERIFY_FAILS=$((BROWSER_VERIFY_FAILS + 1))
    fi
    scroll_current_page

    if (( VISITS % 2 == 0 )); then
      HOT_RESUMES=$((HOT_RESUMES + 1))
      APP_CONNECTED_CHECKS=$((APP_CONNECTED_CHECKS + 1))
      if ! check_connected_in_app "hot_${HOT_RESUMES}"; then
        APP_CONNECTED_FAILS=$((APP_CONNECTED_FAILS + 1))
        log "VPN/app check failed after hot resume"
      fi
      adb -s "$DEVICE" shell am start -n com.android.chrome/com.google.android.apps.chrome.Main >/dev/null 2>&1 || true
      sleep 2
    fi

    if (( VISITS % 5 == 0 )); then
      press_home
      sleep 8
      WARM_RESUMES=$((WARM_RESUMES + 1))
      APP_CONNECTED_CHECKS=$((APP_CONNECTED_CHECKS + 1))
      if ! check_connected_in_app "warm_${WARM_RESUMES}"; then
        APP_CONNECTED_FAILS=$((APP_CONNECTED_FAILS + 1))
        log "VPN/app check failed after warm resume"
      fi
      adb -s "$DEVICE" shell am start -n com.android.chrome/com.google.android.apps.chrome.Main >/dev/null 2>&1 || true
      sleep 2
    fi

    sleep 10
  done
done

END_TS=$(date +%s)
ELAPSED_SEC=$((END_TS - START_TS))

launch_app_warm
sleep 3
screenshot "final_app_state"

disconnect_vpn_if_needed || true
adb -s "$DEVICE" shell svc power stayon false >/dev/null 2>&1 || true

FATAL_COUNT=$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION.*$PKG" || true)
ANR_COUNT=$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -c "ANR in $PKG" || true)
FATAL_COUNT=$(printf '%s' "$FATAL_COUNT" | tail -n 1 | tr -d '\r')
ANR_COUNT=$(printf '%s' "$ANR_COUNT" | tail -n 1 | tr -d '\r')

record_kv "SOAK_DURATION_SECONDS" "$ELAPSED_SEC"
record_kv "BROWSER_VISITS" "$VISITS"
record_kv "HOT_RESUMES" "$HOT_RESUMES"
record_kv "WARM_RESUMES" "$WARM_RESUMES"
record_kv "APP_CONNECTED_CHECKS" "$APP_CONNECTED_CHECKS"
record_kv "APP_CONNECTED_FAILS" "$APP_CONNECTED_FAILS"
record_kv "BROWSER_VERIFY_FAILS" "$BROWSER_VERIFY_FAILS"
record_kv "APP_FATAL_EXCEPTIONS" "$FATAL_COUNT"
record_kv "APP_ANR_COUNT" "$ANR_COUNT"

if [ "$APP_CONNECTED_FAILS" -eq 0 ] && [ "$FATAL_COUNT" -eq 0 ] && [ "$ANR_COUNT" -eq 0 ]; then
  record_kv "OVERALL" "PASS"
else
  record_kv "OVERALL" "FAIL"
fi

log "========== REAL USER SOAK RESULTS =========="
while read -r line; do
  log "  $line"
done < "$RESULTS"
log "==========================================="
