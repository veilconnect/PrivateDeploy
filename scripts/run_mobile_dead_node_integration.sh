#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOBILE_DIR="$ROOT_DIR/mobile"
FLUTTER_BIN="${FLUTTER_BIN:-/home/user/flutter/bin/flutter}"
EMULATOR_BIN="${ANDROID_EMULATOR_BIN:-/home/user/Android/Sdk/emulator/emulator}"
ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
ANDROID_AVD="${ANDROID_AVD:-test_pixel}"
SUB_PORT="${PD_TEST_SUB_PORT:-8765}"
SUB_HOST="${PD_TEST_SUB_HOST:-10.0.2.2}"
PROFILE_NAME="${PD_TEST_PROFILE_NAME:-sstest}"
KEEP_EMULATOR="${PD_KEEP_EMULATOR:-0}"
KEEP_ARTIFACTS="${PD_KEEP_TEST_ARTIFACTS:-0}"

WORK_DIR="$(mktemp -d /tmp/pd-dead-node-it.XXXXXX)"
SUBSCRIPTION_FILE="$WORK_DIR/sub.txt"
HTTP_LOG="$WORK_DIR/http-server.log"
EMULATOR_LOG="$WORK_DIR/emulator.log"
LOGCAT_FILE="$WORK_DIR/logcat.txt"
SCREENSHOT_FILE="$WORK_DIR/failure.png"
UI_DUMP_FILE="$WORK_DIR/vpn-dialog.xml"

HTTP_PID=""
EMULATOR_PID=""
DIALOG_WATCHER_PID=""
DRIVE_PID=""
STARTED_EMULATOR=0
TEST_EXIT_CODE=1

cleanup() {
  set +e

  if [[ -n "$DIALOG_WATCHER_PID" ]]; then
    kill "$DIALOG_WATCHER_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
  fi

  adb -s "$ANDROID_SERIAL" reverse --remove "tcp:${SUB_PORT}" >/dev/null 2>&1 || true

  if [[ "$TEST_EXIT_CODE" -ne 0 ]]; then
    adb -s "$ANDROID_SERIAL" logcat -d >"$LOGCAT_FILE" 2>/dev/null || true
    adb -s "$ANDROID_SERIAL" exec-out screencap -p >"$SCREENSHOT_FILE" 2>/dev/null || true
    echo "Saved failure artifacts to $WORK_DIR"
  elif [[ "$KEEP_ARTIFACTS" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "Saved test artifacts to $WORK_DIR"
  fi

  if [[ "$STARTED_EMULATOR" == "1" && "$KEEP_EMULATOR" != "1" ]]; then
    adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
    if [[ -n "$EMULATOR_PID" ]]; then
      wait "$EMULATOR_PID" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup EXIT

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' was not found" >&2
    exit 1
  fi
}

write_dead_subscription() {
  cat >"$SUBSCRIPTION_FILE" <<'EOF'
ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@1.2.3.4:8388#DeadNode
EOF
}

start_subscription_server() {
  python3 -m http.server "$SUB_PORT" --bind 0.0.0.0 --directory "$WORK_DIR" \
    >"$HTTP_LOG" 2>&1 &
  HTTP_PID=$!

  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:${SUB_PORT}/sub.txt" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  echo "error: failed to start local subscription server on port $SUB_PORT" >&2
  exit 1
}

ensure_emulator() {
  if ! adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
    if [[ ! -x "$EMULATOR_BIN" ]]; then
      echo "error: emulator binary not found at $EMULATOR_BIN" >&2
      exit 1
    fi

    "$EMULATOR_BIN" \
      -avd "$ANDROID_AVD" \
      -no-window \
      -no-snapshot-save \
      -no-boot-anim \
      -gpu swiftshader_indirect \
      -no-audio \
      >"$EMULATOR_LOG" 2>&1 &
    EMULATOR_PID=$!
    STARTED_EMULATOR=1
  fi

  adb -s "$ANDROID_SERIAL" wait-for-device

  for _ in $(seq 1 90); do
    if [[ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
      adb -s "$ANDROID_SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true
      return 0
    fi
    sleep 2
  done

  echo "error: emulator '$ANDROID_SERIAL' did not finish booting" >&2
  exit 1
}

tap_dialog_button() {
  local xml="$1"
  local bounds

  bounds="$(
    grep -m1 'resource-id="android:id/button1"' "$xml" \
      | sed -nE 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/p'
  )"

  if [[ -z "$bounds" ]]; then
    bounds="$(
      grep -m1 'text="OK"' "$xml" \
        | sed -nE 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/p'
    )"
  fi

  if [[ -z "$bounds" ]]; then
    return 1
  fi

  read -r x1 y1 x2 y2 <<<"$bounds"
  local center_x=$(((x1 + x2) / 2))
  local center_y=$(((y1 + y2) / 2))
  adb -s "$ANDROID_SERIAL" shell input tap "$center_x" "$center_y" >/dev/null
}

watch_vpn_dialog() {
  while kill -0 "$DRIVE_PID" >/dev/null 2>&1; do
    if adb -s "$ANDROID_SERIAL" shell dumpsys activity activities 2>/dev/null \
      | grep -q 'com.android.vpndialogs'; then
      adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/pd-vpn-dialog.xml \
        >/dev/null 2>&1 || true
      adb -s "$ANDROID_SERIAL" pull /sdcard/pd-vpn-dialog.xml "$UI_DUMP_FILE" \
        >/dev/null 2>&1 || true
      if tap_dialog_button "$UI_DUMP_FILE"; then
        return 0
      fi
      adb -s "$ANDROID_SERIAL" shell input keyevent 61 >/dev/null 2>&1 || true
      adb -s "$ANDROID_SERIAL" shell input keyevent 66 >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
}

run_test() {
  pushd "$MOBILE_DIR" >/dev/null

  "$FLUTTER_BIN" pub get >/dev/null
  adb -s "$ANDROID_SERIAL" shell pm clear com.privatedeploy.mobile >/dev/null 2>&1 || true
  if [[ "$SUB_HOST" == "127.0.0.1" ]]; then
    adb -s "$ANDROID_SERIAL" reverse "tcp:${SUB_PORT}" "tcp:${SUB_PORT}" >/dev/null
  fi

  "$FLUTTER_BIN" drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/vpn_dead_node_failure_test.dart \
    -d "$ANDROID_SERIAL" \
    --dart-define="PD_TEST_SUBSCRIPTION_URL=http://${SUB_HOST}:${SUB_PORT}/sub.txt" \
    --dart-define="PD_TEST_PROFILE_NAME=${PROFILE_NAME}" &
  DRIVE_PID=$!

  watch_vpn_dialog &
  DIALOG_WATCHER_PID=$!

  wait "$DRIVE_PID"
  TEST_EXIT_CODE=$?
  wait "$DIALOG_WATCHER_PID" >/dev/null 2>&1 || true

  popd >/dev/null
}

main() {
  require_tool adb
  require_tool curl
  require_tool grep
  require_tool python3

  write_dead_subscription
  start_subscription_server
  ensure_emulator

  echo "→ Running dead-node VPN integration test on $ANDROID_SERIAL"
  run_test
  echo "✓ Dead-node VPN integration test passed"
}

main "$@"
