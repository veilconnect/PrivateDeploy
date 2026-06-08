# PrivateDeploy Mobile - Build and Deployment Guide

**English** | [中文](BUILD_AND_DEPLOY.zh-CN.md)

This document provides the complete build, test, and deployment workflow.

---

## 📋 Table of Contents

1. [Development Environment Setup](#开发环境设置)
2. [Flutter Project Build](#flutter-项目构建)
3. [Go Mobile Compilation](#go-mobile-编译)
4. [Android Build and Deployment](#android-构建和部署)
5. [iOS Build and Deployment](#ios-构建和部署)
6. [Continuous Integration](#持续集成)
7. [Troubleshooting](#故障排除)

---

## 🔧 Development Environment Setup

### Required Tools

#### 1. Flutter SDK

```bash
# Download Flutter
git clone https://github.com/flutter/flutter.git -b stable

# Add to PATH
export PATH="$PATH:`pwd`/flutter/bin"

# Verify installation
flutter doctor

# Expected output:
# ✓ Flutter (Channel stable, ...)
# ✓ Android toolchain
# ✓ Xcode (macOS only)
# ✓ VS Code / Android Studio
```

#### 2. Go Environment

```bash
# Install Go 1.21+
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz

# Set environment variables
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# Verify
go version
```

#### 3. gomobile

```bash
# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# Initialize
gomobile init

# Verify
gomobile version
```

#### 4. Android SDK and NDK

```bash
# Set environment variables
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653
export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin

# Install SDK components
sdkmanager "platforms;android-34"
sdkmanager "build-tools;34.0.0"
sdkmanager "ndk;25.2.9519653"
```

#### 5. Xcode (macOS only)

```bash
# Install Xcode from the App Store

# Install command-line tools
xcode-select --install

# Accept the license
sudo xcodebuild -license accept

# Verify
xcodebuild -version
```

---

## 🎯 Flutter Project Build

### 1. Fetch Dependencies

```bash
cd ~/PrivateDeploy/mobile

# Fetch pub dependencies
flutter pub get

# Generate code
flutter pub run build_runner build --delete-conflicting-outputs
```

### 2. Code Generation

```bash
# Retrofit API client
flutter pub run build_runner watch

# Or generate once
flutter pub run build_runner build --delete-conflicting-outputs
```

### 3. Asset Preparation

```bash
# Check asset files
flutter pub run flutter_launcher_icons:main

# Update app icon (if needed)
# Edit the flutter_icons configuration in pubspec.yaml
```

---

## 🔨 Go Mobile Compilation

### Android AAR

```bash
cd gomobile

# Option 1: Use the script
./build-android.sh

# Option 2: Compile manually
gomobile bind \
    -target=android \
    -androidapi=21 \
    -javapkg="com.privatedeploy.mobile.vpncore" \
    -o=../android/app/libs/vpncore.aar \
    .

# Verify
ls -lh ../android/app/libs/vpncore.aar
```

### iOS Framework

```bash
cd gomobile

# Option 1: Use the script
./build-ios.sh

# Option 2: Compile manually
gomobile bind \
    -target=ios \
    -iosversion=12.0 \
    -o=../ios/VPNCore.framework \
    .

# Verify
ls -lh ../ios/VPNCore.framework
lipo -info ../ios/VPNCore.framework/VPNCore
```

---

## 📱 Android Build and Deployment

### Development Build

```bash
cd ~/PrivateDeploy/mobile

# Debug APK
flutter build apk --debug

# Install to device
flutter install

# Or run directly
flutter run
```

### Release Build

#### 1. Configure Signing

Create `android/key.properties`:

```properties
storePassword=<your-store-password>
keyPassword=<your-key-password>
keyAlias=privatedeploy
storeFile=<path-to-keystore>
```

Modify `android/app/build.gradle`:

```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
```

#### 2. Build the Release Version

```bash
# Build APK
flutter build apk --release

# Build App Bundle (recommended for the Play Store)
flutter build appbundle --release

# Output locations:
# build/app/outputs/flutter-apk/app-release.apk
# build/app/outputs/bundle/release/app-release.aab
```

#### 3. Test the Release Version

```bash
# Install the APK
adb install build/app/outputs/flutter-apk/app-release.apk

# View logs
adb logcat | grep PrivateDeploy
```

### Deploy to Google Play

#### 1. Prepare Metadata

- App name: PrivateDeploy
- Package name: com.privatedeploy.mobile
- Version: 1.0.0
- Category: Tools
- Privacy policy URL

#### 2. Create the Listing

1. Sign in to the [Google Play Console](https://play.google.com/console)
2. Create a new app
3. Fill in the store information
4. Upload screenshots (at least 2)
5. Set the content rating

#### 3. Release Process

```bash
# 1. Create an internal testing release
# Upload app-release.aab to internal testing

# 2. Closed testing
# Invite test users and collect feedback

# 3. Open testing (optional)
# Expand the testing scope

# 4. Production release
# Release to production after review approval
```

---

## 🍎 iOS Build and Deployment

### Development Build

```bash
# Open the Xcode project
open ios/Runner.xcworkspace

# Or use the Flutter command
flutter run -d <device-id>

# View available devices
flutter devices
```

### Release Build

#### 1. Configure Signing

In Xcode:

1. Select the **Runner** target
2. Switch to **Signing & Capabilities**
3. Choose the development team
4. Configure the Bundle Identifier: `com.privatedeploy.mobile`
5. Enable **Automatically manage signing**

Repeat the steps above for the **VPNExtension** target.

#### 2. Configure Capabilities

Make sure the following are enabled:
- ✅ Network Extensions (Packet Tunnel)
- ✅ App Groups
- ✅ Keychain Sharing

#### 3. Build the IPA

```bash
# Option 1: Flutter command
flutter build ios --release

# Option 2: Xcode
# Product → Archive
# Organizer → Distribute App

# Option 3: xcodebuild
cd ios
xcodebuild -workspace Runner.xcworkspace \
           -scheme Runner \
           -configuration Release \
           -archivePath build/Runner.xcarchive \
           archive
```

#### 4. Export the IPA

```bash
# Use xcodebuild
xcodebuild -exportArchive \
           -archivePath build/Runner.xcarchive \
           -exportPath build/ipa \
           -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
</plist>
```

### Deploy to the App Store

#### 1. Prepare Metadata

- App name: PrivateDeploy
- Bundle ID: com.privatedeploy.mobile
- Version: 1.0.0
- Category: Utilities
- Privacy policy URL
- Support URL

#### 2. Create an App Store Connect Record

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com)
2. Create a new app
3. Fill in the app information
4. Upload screenshots (iPhone + iPad)
5. Set the age rating

#### 3. Upload the Build

```bash
# Use the Xcode Organizer
# Or use Transporter.app

# Or use altool (command line)
xcrun altool --upload-app \
             --type ios \
             --file build/ipa/Runner.ipa \
             --username "your-apple-id" \
             --password "@keychain:AC_PASSWORD"
```

#### 4. Submit for Review

1. Select the build in App Store Connect
2. Fill in the review information
3. Submit for review
4. Wait for the review result (usually 1-3 days)

---

## 🔄 Continuous Integration

### GitHub Actions

Create `.github/workflows/build.yml`:

```yaml
name: Build and Test

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  build-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.16.0'
          channel: 'stable'

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Install gomobile
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          gomobile init

      - name: Build Go Mobile AAR
        run: |
          cd mobile/gomobile
          ./build-android.sh

      - name: Flutter pub get
        run: |
          cd mobile
          flutter pub get

      - name: Build APK
        run: |
          cd mobile
          flutter build apk --release

      - name: Upload APK
        uses: actions/upload-artifact@v3
        with:
          name: app-release.apk
          path: mobile/build/app/outputs/flutter-apk/app-release.apk

  build-ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.16.0'

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Install gomobile
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          gomobile init

      - name: Build Go Mobile Framework
        run: |
          cd mobile/gomobile
          ./build-ios.sh

      - name: Flutter pub get
        run: |
          cd mobile
          flutter pub get

      - name: Build iOS
        run: |
          cd mobile
          flutter build ios --release --no-codesign

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Flutter
        uses: subosito/flutter-action@v2

      - name: Run tests
        run: |
          cd mobile
          flutter test
```

### Fastlane (optional)

#### Android

`android/fastlane/Fastfile`:

```ruby
platform :android do
  desc "Build and deploy to Play Store"
  lane :deploy do
    gradle(task: "clean")
    gradle(
      task: "bundle",
      build_type: "Release"
    )
    upload_to_play_store(
      track: "internal",
      aab: "../build/app/outputs/bundle/release/app-release.aab"
    )
  end
end
```

#### iOS

`ios/fastlane/Fastfile`:

```ruby
platform :ios do
  desc "Build and deploy to TestFlight"
  lane :beta do
    build_app(
      workspace: "Runner.xcworkspace",
      scheme: "Runner",
      export_method: "app-store"
    )
    upload_to_testflight
  end
end
```

---

## 🐛 Troubleshooting

### Common Errors

#### 1. Flutter Dependency Issues

```bash
# Clean the cache
flutter clean
flutter pub cache repair

# Re-fetch dependencies
flutter pub get
```

#### 2. Android Build Failure

```bash
# Clean the Gradle cache
cd android
./gradlew clean

# Check the NDK
echo $ANDROID_NDK_HOME

# Rebuild
cd ..
flutter build apk
```

#### 3. iOS Build Failure

```bash
# Clean the build
cd ios
xcodebuild clean -workspace Runner.xcworkspace -scheme Runner

# Re-fetch Pods
pod deintegrate
pod install

# Rebuild
cd ..
flutter build ios
```

#### 4. gomobile Compilation Failure

```bash
# Update gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# Clean the Go cache
go clean -modcache

# Recompile
cd gomobile
./build-android.sh
```

### Debugging Tips

#### Flutter

```bash
# Run in debug mode
flutter run --debug

# View verbose logs
flutter run --verbose

# Performance profiling
flutter run --profile
```

#### Android

```bash
# View logs
adb logcat | grep flutter

# View crashes
adb logcat | grep -i crash

# View VPN
adb logcat | grep VPN
```

#### iOS

```bash
# View device logs
idevicesyslog

# View a specific app
idevicesyslog | grep PrivateDeploy

# Use Console.app (macOS)
open /System/Applications/Utilities/Console.app
```

---

## ✅ Release Checklist

### Before Release

- [ ] All functional tests pass
- [ ] Unit tests pass
- [ ] UI tests pass
- [ ] On-device tests pass
- [ ] Performance tests meet the standard
- [ ] Memory leak check
- [ ] Security audit complete
- [ ] Privacy policy ready
- [ ] Changelog written
- [ ] Screenshots and promotional materials prepared

### Android-Specific

- [ ] Signing key stored securely
- [ ] ProGuard rules tested
- [ ] Multi-device testing
- [ ] API 24+ compatibility
- [ ] Play Store metadata complete

### iOS-Specific

- [ ] Certificates and provisioning profiles valid
- [ ] Network Extension tested
- [ ] App Groups configured correctly
- [ ] TestFlight testing complete
- [ ] App Store metadata complete
- [ ] Review preparation materials

---

## 📚 References

- [Flutter Build Guide](https://docs.flutter.dev/deployment)
- [Android Release Process](https://developer.android.com/studio/publish)
- [iOS Release Process](https://developer.apple.com/ios/submit/)
- [gomobile Documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

---

*Last updated: 2024-11-05*
