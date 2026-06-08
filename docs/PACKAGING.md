# PrivateDeploy Packaging and Installer Generation Guide

**English** | [中文](PACKAGING.zh-CN.md)

This document describes how to generate installers for PrivateDeploy on each platform.

## Table of Contents

- [Quick Start](#quick-start)
- [Windows Installer](#windows-installer)
- [Linux Packages](#linux-packages)
- [macOS Disk Image](#macos-disk-image)
- [FAQ](#faq)

## Quick Start

### Using the Unified Script

The simplest approach is to use the unified build script:

```bash
# Use the default version number (1.0.0)
./scripts/build-all.sh

# Specify a version number
./scripts/build-all.sh 1.2.3
```

The script automatically detects the current platform and shows the available packaging options.

## Windows Installer

### Prerequisites

- Windows operating system
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- NSIS (handled automatically by Wails)

### Build Steps

1. **Run the build script**:
   ```bash
   ./scripts/build-windows-installer.sh 1.0.0
   ```

   To use a pre-downloaded `sing-box` archive and verify its SHA256, you can additionally pass:
   ```bash
   SINGBOX_ARCHIVE_PATH=/path/to/sing-box-windows-amd64.zip \
   SINGBOX_SHA256=<sha256> \
   ./scripts/build-windows-installer.sh 1.0.0
   ```

2. **Manual build** (optional):
   ```bash
   # Build the frontend
   cd frontend
   pnpm install
   pnpm run build
   cd ..

   # Build the Windows installer
   PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -tags webkit2_41 -nsis -o PrivateDeploy.exe
   ```

3. **Output file**:
   - Location: `build/bin/PrivateDeploy-{VERSION}-windows-amd64-installer.exe`
   - Type: NSIS installer

### Installer Features

- ✅ Graphical installation wizard
- ✅ Automatically creates Start Menu shortcuts
- ✅ Automatically creates a desktop shortcut
- ✅ Supports silent installation: `/S` parameter
- ✅ Supports an uninstaller

## Linux Packages

### Prerequisites

- Linux operating system (Ubuntu 20.04+ recommended)
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- GTK3 and WebKit2GTK development libraries
- fpm packaging tool

### Installing Dependencies

```bash
# Install system dependencies
sudo apt-get update
sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev

# Install Ruby and fpm
sudo apt-get install -y ruby ruby-dev rubygems build-essential
sudo gem install fpm
```

### Build Steps

1. **Run the build script**:
   ```bash
   # Generate DEB and RPM packages
   ./scripts/build-linux-packages.sh 1.0.0
   ```

2. **Output files**:
   - DEB package: `build/bin/privatedeploy_{VERSION}_amd64.deb`
   - RPM package: `build/bin/privatedeploy-{VERSION}-1.x86_64.rpm`

### Installation Methods

**Debian/Ubuntu (DEB)**:
```bash
sudo dpkg -i build/bin/privatedeploy_1.0.0_amd64.deb
sudo apt-get install -f  # Install dependencies
```

**RedHat/CentOS/Fedora (RPM)**:
```bash
sudo rpm -i build/bin/privatedeploy-1.0.0-1.x86_64.rpm
```

### Package Contents

- Executable: `/usr/bin/privatedeploy`
- Data files: `/usr/share/privatedeploy/data/`
- Desktop shortcut: `/usr/share/applications/privatedeploy.desktop`
- Icon: `/usr/share/pixmaps/privatedeploy.png`

## macOS Disk Image

### Prerequisites

- macOS operating system
- Go 1.21+
- Node.js 18+
- pnpm
- Wails CLI v2
- Xcode Command Line Tools

### Build Steps

1. **Run the build script**:
   ```bash
   ./scripts/build-macos-dmg.sh 1.0.0
   ```

2. **Output file**:
   - Location: `build/bin/PrivateDeploy-{VERSION}-macos.dmg`
   - Type: DMG disk image (Universal Binary - supports both Intel and Apple Silicon)

### Installation Method

1. Double-click the DMG file to open it
2. Drag PrivateDeploy.app into the Applications folder
3. Open the app from Launchpad or Finder

### Universal Binary

The generated DMG contains a Universal Binary that supports both:
- Intel (x86_64) processors
- Apple Silicon (ARM64) processors

## Building the Executable Only

If you only need the executable and not the installer:

```bash
# Build the frontend
cd frontend
pnpm install
pnpm run build
cd ..

# Build the executable
PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -tags webkit2_41
```

The executable is located in the `build/bin/` directory.

## Cross-Platform Builds

### Building the Windows Version on Linux

```bash
# Requires mingw-w64
sudo apt-get install mingw-w64

# Set cross-compilation environment variables
export GOOS=windows
export GOARCH=amd64
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++

# Build
PRIVATEDEPLOY_SKIP_DISPLAY_CHECK=1 wails build -m -s -trimpath -o PrivateDeploy.exe
```

**Note**: The NSIS installer can only be generated on Windows.

## CI/CD Automated Builds

The project includes GitHub Actions workflows that can automatically build installers for all platforms:

- **Release versions**: Triggered by pushing a `v*` tag (`release.yml`)
- **Rolling releases**: Triggered by pushing to the main branch (`rolling-release.yml`)

See the `.github/workflows/` directory for details.

## FAQ

### Q: "NSIS not found" on Windows

**A**: Wails downloads NSIS automatically. If it fails, you can install it manually:
1. Download NSIS from https://nsis.sourceforge.io/
2. Install to the default path
3. Re-run the build script

### Q: "fpm not found" on Linux

**A**: Install the fpm packaging tool:
```bash
sudo apt-get install ruby ruby-dev rubygems build-essential
sudo gem install fpm
```

### Q: Code signing error on macOS

**A**: Development builds do not need signing. To publish to the App Store, you need to:
1. Register an Apple Developer account
2. Create a developer certificate
3. Sign the app with the `codesign` command

### Q: How to reduce the installer size?

**A**: You can use UPX compression:
```bash
wails build -upx -upxflags "--best --lzma"
```

**Note**: UPX may cause false positives in some antivirus software.

### Q: Out-of-memory error during build

**A**: You can limit parallel builds:
```bash
GOMAXPROCS=2 wails build ...
```

## Script Permissions

All scripts require execute permissions:

```bash
chmod +x scripts/*.sh
```

## More Information

- [Wails Official Documentation](https://wails.io/docs/guides/building)
- [FPM Packaging Tool](https://fpm.readthedocs.io/)
- [NSIS Documentation](https://nsis.sourceforge.io/Docs/)

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0).
