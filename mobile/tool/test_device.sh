#!/bin/bash
# Automated test script for a single device
# Usage: test_device.sh <device_serial> <output_dir>

DEVICE="$1"
OUTDIR="$2"
PKG="com.privatedeploy.mobile"
ACTIVITY="$PKG/.MainActivity"

mkdir -p "$OUTDIR"

log() { echo "[$DEVICE] $*"; }
screenshot() { adb -s "$DEVICE" exec-out screencap -p > "$OUTDIR/$1.png" 2>/dev/null; }
tap() { adb -s "$DEVICE" shell input tap "$1" "$2" 2>/dev/null; }

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
adb -s "$DEVICE" shell am start -n "$ACTIVITY" 2>/dev/null > /dev/null
sleep 4
screenshot "01_launch"

# Check app is running
PID=$(adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r')
if [ -z "$PID" ]; then
    log "FAIL: App did not launch"
    echo "TEST1_LAUNCH=FAIL" > "$OUTDIR/results.txt"
    exit 1
fi
log "PASS: App launched (PID=$PID)"
echo "TEST1_LAUNCH=PASS" > "$OUTDIR/results.txt"

# ========== TEST 2: Connect without config ==========
log "TEST 2: Connect without config"
# Get Connect button coordinates from UI dump
adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
CONNECT_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="Connect"' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

if [ -n "$CONNECT_BOUNDS" ]; then
    # Parse bounds [x1,y1][x2,y2] -> center
    X1=$(echo "$CONNECT_BOUNDS" | grep -o '\[' | head -1; echo "$CONNECT_BOUNDS" | sed 's/.*\[\([0-9]*\),.*/\1/' | head -1)
    CX=$(echo "$CONNECT_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
    CY=$(echo "$CONNECT_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
    tap "$CX" "$CY"
    sleep 3
    screenshot "02_no_config"

    # Check app still running
    PID=$(adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r')
    if [ -z "$PID" ]; then
        log "FAIL: App crashed on connect without config"
        echo "TEST2_NO_CONFIG=FAIL" >> "$OUTDIR/results.txt"
    else
        log "PASS: No crash on connect without config"
        echo "TEST2_NO_CONFIG=PASS" >> "$OUTDIR/results.txt"
    fi
else
    log "SKIP: Could not find Connect button"
    echo "TEST2_NO_CONFIG=SKIP" >> "$OUTDIR/results.txt"
fi

# ========== TEST 3: Create profile with invalid config ==========
log "TEST 3: Create invalid profile"

# Navigate to Profiles tab - find from UI dump
adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
PROFILES_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="Profiles' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

if [ -n "$PROFILES_BOUNDS" ]; then
    PCX=$(echo "$PROFILES_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
    PCY=$(echo "$PROFILES_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
    tap "$PCX" "$PCY"
    sleep 2

    # Find and tap Create Profile button
    adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
    CREATE_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="Create Profile"' | grep 'Button' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

    if [ -n "$CREATE_BOUNDS" ]; then
        CCX=$(echo "$CREATE_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
        CCY=$(echo "$CREATE_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
        tap "$CCX" "$CCY"
        sleep 2

        # Find Profile Name field and type
        adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
        NAME_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'hint="Profile Name' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

        if [ -n "$NAME_BOUNDS" ]; then
            NCX=$(echo "$NAME_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
            NCY=$(echo "$NAME_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
            tap "$NCX" "$NCY"
            sleep 0.5
            adb -s "$DEVICE" shell input text "test-invalid" 2>/dev/null
            sleep 0.5

            # Find config field and type invalid JSON
            CONFIG_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'hint="sing-box JSON Config' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)
            if [ -n "$CONFIG_BOUNDS" ]; then
                CFCX=$(echo "$CONFIG_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
                CFCY=$(echo "$CONFIG_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
                tap "$CFCX" "$CFCY"
                sleep 0.5
                adb -s "$DEVICE" shell input text 'not-json' 2>/dev/null
                sleep 0.5
            fi

            # Dismiss keyboard and tap Create
            adb -s "$DEVICE" shell input keyevent KEYCODE_BACK 2>/dev/null
            sleep 0.5
            adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
            CREATE_BTN=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="Create"' | grep 'Button' | grep -v "Create Profile" | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

            if [ -n "$CREATE_BTN" ]; then
                CBCX=$(echo "$CREATE_BTN" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
                CBCY=$(echo "$CREATE_BTN" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
                tap "$CBCX" "$CBCY"
                sleep 2
                screenshot "03_profile_created"
            fi
        fi
    fi
fi

# ========== TEST 4: Connect with invalid config ==========
log "TEST 4: Connect with invalid/no-outbounds config"

# Go to VPN tab
adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
VPN_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="VPN' | grep 'Tab 1' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

if [ -n "$VPN_BOUNDS" ]; then
    VCX=$(echo "$VPN_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
    VCY=$(echo "$VPN_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
    tap "$VCX" "$VCY"
    sleep 2

    # Tap Connect
    adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
    CONNECT_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep 'content-desc="Connect"' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)

    if [ -n "$CONNECT_BOUNDS" ]; then
        CX=$(echo "$CONNECT_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
        CY=$(echo "$CONNECT_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
        tap "$CX" "$CY"
        sleep 4
        screenshot "04_invalid_connect"

        # Check app still running
        PID=$(adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r')
        if [ -z "$PID" ]; then
            log "FAIL: App crashed on connect with invalid config"
            echo "TEST4_INVALID_CONFIG=FAIL" >> "$OUTDIR/results.txt"
        else
            log "PASS: No crash on connect with invalid config"
            echo "TEST4_INVALID_CONFIG=PASS" >> "$OUTDIR/results.txt"
        fi
    else
        log "SKIP: Could not find Connect button"
        echo "TEST4_INVALID_CONFIG=SKIP" >> "$OUTDIR/results.txt"
    fi
else
    log "SKIP: Could not find VPN tab"
    echo "TEST4_INVALID_CONFIG=SKIP" >> "$OUTDIR/results.txt"
fi

# ========== TEST 5: Tab navigation ==========
log "TEST 5: Tab navigation"
TABS_OK=true

for TAB_NAME in "Profiles" "Cloud" "Settings" "VPN"; do
    adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null > /dev/null
    TAB_BOUNDS=$(adb -s "$DEVICE" shell cat /sdcard/ui.xml 2>/dev/null | tr '>' '\n' | grep "content-desc=\"$TAB_NAME" | grep 'Tab' | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"' | head -1)
    if [ -n "$TAB_BOUNDS" ]; then
        TX=$(echo "$TAB_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\1 \3/' | awk '{print int(($1+$2)/2)}')
        TY=$(echo "$TAB_BOUNDS" | sed 's/bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]"/\2 \4/' | awk '{print int(($1+$2)/2)}')
        tap "$TX" "$TY"
        sleep 1
    fi

    PID=$(adb -s "$DEVICE" shell pidof "$PKG" 2>/dev/null | tr -d '\r')
    if [ -z "$PID" ]; then
        log "FAIL: App crashed on $TAB_NAME tab"
        TABS_OK=false
        break
    fi
done

screenshot "05_tabs_done"
if $TABS_OK; then
    log "PASS: All tabs navigable"
    echo "TEST5_TABS=PASS" >> "$OUTDIR/results.txt"
else
    log "FAIL: Tab navigation failed"
    echo "TEST5_TABS=FAIL" >> "$OUTDIR/results.txt"
fi

# ========== TEST 6: Check logcat for crashes ==========
log "TEST 6: Crash check in logcat"
CRASHES=$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION.*$PKG" || echo "0")
if [ "$CRASHES" = "0" ]; then
    log "PASS: No FATAL exceptions in logcat"
    echo "TEST6_LOGCAT=PASS" >> "$OUTDIR/results.txt"
else
    log "FAIL: Found $CRASHES FATAL exceptions"
    echo "TEST6_LOGCAT=FAIL" >> "$OUTDIR/results.txt"
fi

# Summary
log "========== RESULTS =========="
cat "$OUTDIR/results.txt" | while read line; do
    log "  $line"
done
log "============================="
