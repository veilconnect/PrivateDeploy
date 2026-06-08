# Packaging Scripts

**English** | [中文](README.zh-CN.md)

This directory contains scripts used to generate PrivateDeploy installers.

## Available Scripts

| Script | Platform | Description | Output |
|------|------|------|------|
| `build-all.sh` | All platforms | Unified build script, auto-detects platform | Depends on selection |
| `build-windows-installer.sh` | Windows | Generates the Windows NSIS installer | `.exe` installer |
| `build-linux-packages.sh` | Linux | Generates DEB and RPM packages | `.deb` and `.rpm` |
| `build-macos-dmg.sh` | macOS | Generates the macOS DMG disk image | `.dmg` image |
| `protocol_speed_compare.py` | Linux/macOS | Speed test by protocol (SS/HY2/VLESS/Trojan, based on sing-box + curl) | `output/benchmarks/protocol_speed_compare_*.{json,tsv}` |
| `local_gui_vultr_smoke.sh` | Linux | Actually creates 1 Vultr node through the GUI in a local desktop session, verifies ports, and destroys it | `output/gui-smoke/<run-id>/` |
| `local_gui_container_smoke.sh` | Linux | Runs a local non-destructive GUI smoke in a Docker container; by default uses an isolated Xvfb for headless DOM-ready functional acceptance, and host display passthrough is for experimental use only when explicitly enabled | `output/gui-smoke/<run-id>/` |
| `run_mobile_dead_node_integration.sh` | Linux | Imports an unreachable subscription on an Android emulator, automatically accepts the VPN authorization, and asserts that the app returns to the failed state | Keeps `/tmp/pd-dead-node-it.*` on failure |
| `windows_remote_vpn_browser_smoke.py` | Linux + remote Windows | Connects PrivateDeploy on a remote Windows host via WinRM + RDP, opens Chrome, and browses sites in sequence | `output/windows-vpn-browser-smoke/<run-id>/` |

## Quick Start

### Recommended Approach (Using the Unified Script)

```bash
# Interactive build
./scripts/build-all.sh

# Specify a version number
./scripts/build-all.sh 1.2.3
```

### Using Individual Scripts Directly

```bash
# Windows NSIS installer
./scripts/build-windows-installer.sh 1.0.0

# Windows NSIS installer (using a local archive and verifying SHA256)
SINGBOX_ARCHIVE_PATH=/path/to/sing-box-windows-amd64.zip \
SINGBOX_SHA256=<sha256> \
./scripts/build-windows-installer.sh 1.0.0

# Linux DEB + RPM packages
./scripts/build-linux-packages.sh 1.0.0

# macOS DMG image
./scripts/build-macos-dmg.sh 1.0.0

# Protocol speed test (reads data/cloud/vultr-nodes.json by default)
python3 scripts/protocol_speed_compare.py --rounds 3

# Local GUI real-deployment smoke (reads /tmp/vultr_api_key.txt by default)
./scripts/local_gui_vultr_smoke.sh

# Local containerized non-destructive GUI smoke (reads build/bin/data by default, liveness judged by DOM-ready under Xvfb)
./scripts/local_gui_container_smoke.sh

# Android emulator dead-node regression (uses test_pixel and emulator-5554 by default)
./scripts/run_mobile_dead_node_integration.sh

# Remote Windows VPN browsing smoke (depends on xfreerdp / xdotool / WinRM)
PD_WIN_HOST=192.0.2.10 \
PD_WIN_USER=Administrator \
PD_WIN_PASS='secret' \
python3 scripts/windows_remote_vpn_browser_smoke.py

# Remote Windows VPN browsing smoke (restores to the baseline proxy and user.yaml toggles by default)
# If you need to strictly restore the pre-collection state, explicitly add --restore-mode original
PD_WIN_HOST=192.0.2.10 \
PD_WIN_USER=Administrator \
PD_WIN_PASS='secret' \
python3 scripts/windows_remote_vpn_browser_smoke.py \
  --restore-mode baseline \
  --restore-proxy-enable 1 \
  --restore-proxy-server 127.0.0.1:7890 \
  --restore-auto-set-system-proxy false \
  --restore-system-proxy-policy-initialized false

# Remote Windows 30-minute real-user soak (browsing + periodically switching back to check the app)
PD_WIN_HOST=192.0.2.10 \
PD_WIN_USER=Administrator \
PD_WIN_PASS='secret' \
python3 scripts/windows_remote_vpn_browser_smoke.py \
  --duration-minutes 30 \
  --switch-back-to-app \
  --app-check-every 1
```

## Prerequisites

### Common Requirements for All Platforms
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2

### Windows Specific
- NSIS (handled automatically by Wails)

### Linux Specific
```bash
# System libraries
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.1-dev

# Packaging tools
sudo apt-get install ruby ruby-dev rubygems build-essential
sudo gem install fpm

# Extra dependencies for the local GUI smoke
sudo apt-get install xvfb xdotool imagemagick jq curl

# Extra dependencies for the containerized GUI smoke
sudo apt-get install docker.io

# Extra dependencies for the remote Windows VPN browsing smoke
sudo apt-get install freerdp2-x11 xdotool imagemagick smbclient python3
python3 -m pip install pywinrm

# Extra dependencies for the Android emulator dead-node regression
sudo apt-get install curl python3
```

### macOS Specific
- Xcode Command Line Tools

## Output Locations

All generated installers are located in the `build/bin/` directory:

- Windows: `PrivateDeploy-{VERSION}-windows-amd64-installer.exe`
- Linux DEB: `privatedeploy_{VERSION}_amd64.deb`
- Linux RPM: `privatedeploy-{VERSION}-1.x86_64.rpm`
- macOS: `PrivateDeploy-{VERSION}-macos.dmg`

## Detailed Documentation

See [`docs/PACKAGING.md`](../docs/PACKAGING.md) for the complete packaging guide.

## Troubleshooting

### "Permission denied"
```bash
chmod +x scripts/*.sh
```

### "fpm not found" (Linux)
```bash
sudo gem install fpm
```

### "wails not found"
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

## Notes

1. **Version number**: We recommend using semantic version numbers (e.g. `1.2.3`)
2. **Cleanup**: Old files are automatically cleaned up before building
3. **Platform restrictions**:
   - The NSIS installer can only be generated on Windows
   - The DMG image can only be generated on macOS
   - DEB/RPM packages can be generated on any platform (requires fpm)
