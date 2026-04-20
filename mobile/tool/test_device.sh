#!/bin/bash
# Automated test script for a single device
# Usage: test_device.sh <device_serial> <output_dir>

set -u

DEVICE="$1"
OUTDIR="$2"
PKG="com.privatedeploy.mobile"
ACTIVITY="$PKG/.MainActivity"
UI_XML="/sdcard/ui.xml"
WORKSPACE_PATTERN='content-desc="(Workspace|工作区)"|text="(Workspace|工作区)"'
CONNECT_PATTERN='content-desc="(Connect|连接)"|text="(Connect|连接)"'
CREATE_PROFILE_PATTERN='content-desc="(Create [Pp]rofile|Create profile|创建配置)"|text="(Create [Pp]rofile|Create profile|创建配置)"'
IMPORT_PROFILE_PATTERN='content-desc="(Import [Pp]rofile|Import profile|导入配置)"|text="(Import [Pp]rofile|Import profile|导入配置)"'
SETTINGS_PATTERN='content-desc="(Settings|设置)"|text="(Settings|设置)"'
CLOUD_API_KEY_PATTERN='content-desc="(Cloud API Key|云端 API Key|Set API Key|设置 API Key)"|text="(Cloud API Key|云端 API Key|Set API Key|设置 API Key)"'
CANCEL_PATTERN='content-desc="(Cancel|取消)"|text="(Cancel|取消)"'
CREATE_BUTTON_PATTERN='content-desc="(Create|创建)"|text="(Create|创建)"'
VERIFY_SAVE_PATTERN='content-desc="(Verify (&amp;|&) Save|验证并保存)"|text="(Verify (&amp;|&) Save|验证并保存)"'

mkdir -p "$OUTDIR"

log() { echo "[$DEVICE] $*"; }
screenshot() { adb -s "$DEVICE" exec-out screencap -p > "$OUTDIR/$1.png" 2>/dev/null; }
tap() { adb -s "$DEVICE" shell input tap "$1" "$2" 2>/dev/null; }
press_back() { adb -s "$DEVICE" shell input keyevent KEYCODE_BACK 2>/dev/null; }
dump_ui() { adb -s "$DEVICE" shell uiautomator dump "$UI_XML" >/dev/null 2>&1 && adb -s "$DEVICE" shell cat "$UI_XML" 2>/dev/null; }
record_result() { echo "$1=$2" >> "$OUTDIR/results.txt"; }
app_pid() { adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r'; }
current_focus() { adb -s "$DEVICE" shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' || true; }
app_is_foreground() { current_focus | grep -q "$ACTIVITY"; }
app_is_running() { [ -n "$(app_pid)" ]; }

unlock_device() {
    adb -s "$DEVICE" shell svc power stayon true >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell cmd statusbar collapse >/dev/null 2>&1 || true
    adb -s "$DEVICE" shell input swipe 540 1900 540 500 180 >/dev/null 2>&1 || true
    sleep 1
    adb -s "$DEVICE" shell cmd statusbar collapse >/dev/null 2>&1 || true
}

launch_app() {
    unlock_device
    adb -s "$DEVICE" shell am force-stop "$PKG" 2>/dev/null >/dev/null
    adb -s "$DEVICE" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 2>/dev/null >/dev/null
    sleep 3
    unlock_device
}

ensure_foreground() {
    if app_is_foreground; then
        return 0
    fi
    launch_app
    app_is_foreground
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

wait_for_bounds() {
    local pattern="$1"
    local attempts="${2:-10}"
    local delay="${3:-1}"
    local bounds=""
    local i

    for ((i = 0; i < attempts; i++)); do
        bounds=$(find_bounds "$pattern")
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
    tap $(echo "$center" | awk '{print $1}') $(echo "$center" | awk '{print $2}')
}

enter_text_at_bounds() {
    local bounds="$1"
    local text="$2"

    tap_bounds "$bounds"
    sleep 1
    adb -s "$DEVICE" shell input text "$text" 2>/dev/null
    sleep 1
}

# Get device info
ANDROID_VER=$(adb -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null)
MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
SCREEN=$(adb -s "$DEVICE" shell wm size 2>/dev/null | grep "Physical" | awk '{print $3}')
log "Device: $MODEL, Android $ANDROID_VER, Screen: $SCREEN"
unlock_device

# Clear any previous data
adb -s "$DEVICE" shell pm clear "$PKG" 2>/dev/null > /dev/null
sleep 1

# ========== TEST 1: App Launch ==========
log "TEST 1: App launch"
launch_app
screenshot "01_launch"

# Check app is running in foreground
PID=$(app_pid)
WORKSPACE_BOUNDS=$(wait_for_bounds "$WORKSPACE_PATTERN" 10 1 || true)
if [ -z "$PID" ] || ! app_is_foreground || [ -z "$WORKSPACE_BOUNDS" ]; then
    log "FAIL: App did not launch"
    echo "TEST1_LAUNCH=FAIL" > "$OUTDIR/results.txt"
    exit 1
fi
log "PASS: App launched (PID=$PID)"
echo "TEST1_LAUNCH=PASS" > "$OUTDIR/results.txt"

# ========== TEST 2: Connect without config ==========
log "TEST 2: Connect without config"
ensure_foreground || true
CONNECT_BOUNDS=$(wait_for_bounds "$CONNECT_PATTERN" 5 1 || true)

if [ -n "$CONNECT_BOUNDS" ]; then
    tap_bounds "$CONNECT_BOUNDS"
    sleep 3
    screenshot "02_no_config"

    if ! app_is_running || ! app_is_foreground; then
        log "FAIL: App crashed on connect without config"
        record_result "TEST2_NO_CONFIG" "FAIL"
    else
        log "PASS: No crash on connect without config"
        record_result "TEST2_NO_CONFIG" "PASS"
    fi
else
    log "FAIL: Could not find Connect button on workspace screen"
    record_result "TEST2_NO_CONFIG" "FAIL"
fi

# ========== TEST 3: Create profile with invalid config ==========
log "TEST 3: Create invalid profile"
ensure_foreground || true
CREATE_FAB_BOUNDS=$(wait_for_bounds "$CREATE_PROFILE_PATTERN" 5 1 || true)

if [ -n "$CREATE_FAB_BOUNDS" ]; then
    tap_bounds "$CREATE_FAB_BOUNDS"
    sleep 2

    NAME_BOUNDS=$(wait_for_bounds 'class="android.widget.EditText"' 5 1 || true)
    CONFIG_BOUNDS=$(find_nth_bounds 'class="android.widget.EditText"' 2)
    CREATE_BTN=$(wait_for_bounds "$CREATE_BUTTON_PATTERN" 5 1 || true)

    if [ -n "$NAME_BOUNDS" ] && [ -n "$CONFIG_BOUNDS" ] && [ -n "$CREATE_BTN" ]; then
        enter_text_at_bounds "$NAME_BOUNDS" "test-invalid"
        enter_text_at_bounds "$CONFIG_BOUNDS" "not-json"

        adb -s "$DEVICE" shell input keyevent KEYCODE_BACK 2>/dev/null
        sleep 1
        tap_bounds "$CREATE_BTN"
        sleep 2
        screenshot "03_invalid_profile"

        if ! app_is_running || ! app_is_foreground; then
            log "FAIL: App crashed while creating invalid profile"
            record_result "TEST3_INVALID_PROFILE" "FAIL"
        else
            log "PASS: Invalid profile flow did not crash"
            record_result "TEST3_INVALID_PROFILE" "PASS"
        fi
    else
        log "FAIL: Could not find create profile dialog fields"
        record_result "TEST3_INVALID_PROFILE" "FAIL"
    fi
else
    log "FAIL: Could not find Create Profile action"
    record_result "TEST3_INVALID_PROFILE" "FAIL"
fi

# Best-effort dismiss any open modal before the next screen-level test.
CANCEL_BOUNDS=$(find_bounds "$CANCEL_PATTERN")
if [ -n "$CANCEL_BOUNDS" ]; then
    tap_bounds "$CANCEL_BOUNDS"
    sleep 1
else
    press_back
    sleep 1
fi
ensure_foreground || true

# ========== TEST 4: Invalid API key dialog ==========
log "TEST 4: Invalid API key dialog"

ensure_foreground || true
API_KEY_BOUNDS=$(wait_for_bounds "$CLOUD_API_KEY_PATTERN" 5 1 || true)

if [ -n "$API_KEY_BOUNDS" ]; then
    tap_bounds "$API_KEY_BOUNDS"
    sleep 2

    API_KEY_FIELD_BOUNDS=$(wait_for_bounds 'class="android.widget.EditText"' 5 1 || true)
    VERIFY_SAVE_BOUNDS=$(wait_for_bounds "$VERIFY_SAVE_PATTERN" 5 1 || true)

    if [ -n "$API_KEY_FIELD_BOUNDS" ] && [ -n "$VERIFY_SAVE_BOUNDS" ]; then
        enter_text_at_bounds "$API_KEY_FIELD_BOUNDS" "INVALID_TEST_KEY"
        adb -s "$DEVICE" shell input keyevent KEYCODE_BACK 2>/dev/null
        sleep 1
        tap_bounds "$VERIFY_SAVE_BOUNDS"
        sleep 4
        screenshot "04_invalid_api_key"

        if ! app_is_running || ! app_is_foreground; then
            log "FAIL: App crashed on invalid API key flow"
            record_result "TEST4_INVALID_API_KEY" "FAIL"
        else
            log "PASS: Invalid API key flow did not crash"
            record_result "TEST4_INVALID_API_KEY" "PASS"
        fi
    else
        log "FAIL: Could not find API key dialog controls"
        record_result "TEST4_INVALID_API_KEY" "FAIL"
    fi
else
    log "FAIL: Could not find API key action"
    record_result "TEST4_INVALID_API_KEY" "FAIL"
fi

# Best-effort dismiss any open modal before navigating to settings.
CANCEL_BOUNDS=$(find_bounds "$CANCEL_PATTERN")
if [ -n "$CANCEL_BOUNDS" ]; then
    tap_bounds "$CANCEL_BOUNDS"
    sleep 1
else
    press_back
    sleep 1
fi
ensure_foreground || true

# ========== TEST 5: Settings navigation ==========
log "TEST 5: Settings navigation"
SETTINGS_BOUNDS=$(wait_for_bounds "$SETTINGS_PATTERN" 5 1 || true)

if [ -n "$SETTINGS_BOUNDS" ]; then
    tap_bounds "$SETTINGS_BOUNDS"
    sleep 2
    screenshot "05_settings_open"

    if ! app_is_running || ! app_is_foreground; then
        log "FAIL: App crashed while opening settings"
        record_result "TEST5_SETTINGS" "FAIL"
    else
        press_back
        sleep 2
        ensure_foreground || true
        WORKSPACE_BOUNDS=$(find_bounds "$WORKSPACE_PATTERN")
        if [ -n "$WORKSPACE_BOUNDS" ] && app_is_running && app_is_foreground; then
            log "PASS: Settings opened and returned to workspace"
            record_result "TEST5_SETTINGS" "PASS"
        else
            log "FAIL: Could not return from settings to workspace"
            record_result "TEST5_SETTINGS" "FAIL"
        fi
    fi
else
    log "FAIL: Could not find Settings action"
    record_result "TEST5_SETTINGS" "FAIL"
fi

# ========== TEST 6: Check logcat for crashes ==========
log "TEST 6: Crash check in logcat"
CRASHES=$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION.*$PKG" || true)
CRASHES=$(printf '%s' "$CRASHES" | tail -n 1 | tr -d '\r')
if [ "$CRASHES" = "0" ]; then
    log "PASS: No FATAL exceptions in logcat"
    record_result "TEST6_LOGCAT" "PASS"
else
    log "FAIL: Found $CRASHES FATAL exceptions"
    record_result "TEST6_LOGCAT" "FAIL"
fi

# Summary
log "========== RESULTS =========="
cat "$OUTDIR/results.txt" | while read line; do
    log "  $line"
done
log "============================="
