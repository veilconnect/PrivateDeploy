#!/bin/bash
# Automated test script for a single device
# Usage: test_device.sh <device_serial> <output_dir>

set -u

DEVICE="$1"
OUTDIR="$2"
PKG="com.privatedeploy.mobile"
ACTIVITY="$PKG/.MainActivity"
UI_XML="/sdcard/ui.xml"

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

launch_app() {
    adb -s "$DEVICE" shell am force-stop "$PKG" 2>/dev/null >/dev/null
    adb -s "$DEVICE" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 2>/dev/null >/dev/null
    sleep 3
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

tap_bounds() {
    local bounds="$1"
    local center
    center=$(bounds_center "$bounds")
    tap $(echo "$center" | awk '{print $1}') $(echo "$center" | awk '{print $2}')
}

# Get device info
ANDROID_VER=$(adb -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null)
MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
SCREEN=$(adb -s "$DEVICE" shell wm size 2>/dev/null | grep "Physical" | awk '{print $3}')
log "Device: $MODEL, Android $ANDROID_VER, Screen: $SCREEN"

# Clear any previous data
adb -s "$DEVICE" shell pm clear "$PKG" 2>/dev/null > /dev/null
sleep 1

# ========== TEST 1: App Launch ==========
log "TEST 1: App launch"
launch_app
screenshot "01_launch"

# Check app is running in foreground
PID=$(app_pid)
if [ -z "$PID" ] || ! app_is_foreground; then
    log "FAIL: App did not launch"
    echo "TEST1_LAUNCH=FAIL" > "$OUTDIR/results.txt"
    exit 1
fi
log "PASS: App launched (PID=$PID)"
echo "TEST1_LAUNCH=PASS" > "$OUTDIR/results.txt"

# ========== TEST 2: Connect without config ==========
log "TEST 2: Connect without config"
ensure_foreground || true
CONNECT_BOUNDS=$(find_bounds 'content-desc="Connect"')

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
    log "FAIL: Could not find Connect button on VPN screen"
    record_result "TEST2_NO_CONFIG" "FAIL"
fi

# ========== TEST 3: Create profile with invalid config ==========
log "TEST 3: Create invalid profile"

# Navigate to Profiles tab - find from UI dump
ensure_foreground || true
PROFILES_BOUNDS=$(find_bounds 'content-desc="Profiles')

if [ -n "$PROFILES_BOUNDS" ]; then
    tap_bounds "$PROFILES_BOUNDS"
    sleep 2

    # Find and tap Create Profile button
    CREATE_BOUNDS=$(find_bounds 'content-desc="Create Profile"')

    if [ -n "$CREATE_BOUNDS" ]; then
        tap_bounds "$CREATE_BOUNDS"
        sleep 2

        # Find Profile Name field and type
        NAME_BOUNDS=$(find_bounds 'hint="Profile Name')

        if [ -n "$NAME_BOUNDS" ]; then
            tap_bounds "$NAME_BOUNDS"
            sleep 0.5
            adb -s "$DEVICE" shell input text "test-invalid" 2>/dev/null
            sleep 0.5

            # Find config field and type invalid JSON
            CONFIG_BOUNDS=$(find_bounds 'hint="sing-box JSON Config')
            if [ -n "$CONFIG_BOUNDS" ]; then
                tap_bounds "$CONFIG_BOUNDS"
                sleep 0.5
                adb -s "$DEVICE" shell input text 'not-json' 2>/dev/null
                sleep 0.5
            fi

            # Dismiss keyboard and tap Create
            adb -s "$DEVICE" shell input keyevent KEYCODE_BACK 2>/dev/null
            sleep 0.5
            CREATE_BTN=$(find_bounds 'content-desc="Create"|text="Create"')

            if [ -n "$CREATE_BTN" ]; then
                tap_bounds "$CREATE_BTN"
                sleep 2
                screenshot "03_profile_created"
            fi
        fi
    fi
fi

# Best-effort dismiss any open modal before the next screen-level test.
press_back
sleep 1
ensure_foreground || true

# ========== TEST 4: Connect with invalid config ==========
log "TEST 4: Connect with invalid/no-outbounds config"

# Go to VPN tab
ensure_foreground || true
VPN_BOUNDS=$(find_bounds 'content-desc="VPN')

if [ -n "$VPN_BOUNDS" ]; then
    tap_bounds "$VPN_BOUNDS"
    sleep 2

    # Tap Connect
    CONNECT_BOUNDS=$(find_bounds 'content-desc="Connect"')

    if [ -n "$CONNECT_BOUNDS" ]; then
        tap_bounds "$CONNECT_BOUNDS"
        sleep 4
        screenshot "04_invalid_connect"

        if ! app_is_running || ! app_is_foreground; then
            log "FAIL: App crashed on connect with invalid config"
            record_result "TEST4_INVALID_CONFIG" "FAIL"
        else
            log "PASS: No crash on connect with invalid config"
            record_result "TEST4_INVALID_CONFIG" "PASS"
        fi
    else
        log "FAIL: Could not find Connect button on VPN screen"
        record_result "TEST4_INVALID_CONFIG" "FAIL"
    fi
else
    log "FAIL: Could not find VPN tab"
    record_result "TEST4_INVALID_CONFIG" "FAIL"
fi

# ========== TEST 5: Tab navigation ==========
log "TEST 5: Tab navigation"
TABS_OK=true

for TAB_NAME in "Profiles" "Cloud" "Settings" "VPN"; do
    ensure_foreground || true
    TAB_BOUNDS=$(find_bounds "content-desc=\"$TAB_NAME")
    if [ -n "$TAB_BOUNDS" ]; then
        tap_bounds "$TAB_BOUNDS"
        sleep 1
    fi

    if ! app_is_running || ! app_is_foreground; then
        log "WARN: App lost foreground on $TAB_NAME tab, retrying once"
        launch_app
        TAB_BOUNDS=$(find_bounds "content-desc=\"$TAB_NAME")
        if [ -n "$TAB_BOUNDS" ]; then
            tap_bounds "$TAB_BOUNDS"
            sleep 1
        fi

        if ! app_is_running || ! app_is_foreground; then
            log "FAIL: App crashed on $TAB_NAME tab"
            current_focus | while read -r line; do
                log "  focus: $line"
            done
            TABS_OK=false
            break
        fi
    fi
done

screenshot "05_tabs_done"
if $TABS_OK; then
    log "PASS: All tabs navigable"
    record_result "TEST5_TABS" "PASS"
else
    log "FAIL: Tab navigation failed"
    record_result "TEST5_TABS" "FAIL"
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
