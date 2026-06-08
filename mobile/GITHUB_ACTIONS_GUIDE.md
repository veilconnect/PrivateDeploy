# GitHub Actions Automated Build Guide

**English** | [中文](GITHUB_ACTIONS_GUIDE.zh-CN.md)

This document explains in detail how to use GitHub Actions to automatically build and test the PrivateDeploy Mobile project.

---

## 📋 Table of Contents

1. [Quick Start](#quick-start)
2. [Workflow Overview](#workflow-overview)
3. [Trigger Methods](#trigger-methods)
4. [Build Artifacts](#build-artifacts)
5. [Release Process](#release-process)
6. [Troubleshooting](#troubleshooting)

---

## 🚀 Quick Start

### 1. Push Code to GitHub

```bash
cd ~/PrivateDeploy/mobile

# Initialize Git repository (if not already done)
git init

# Add remote repository
git remote add origin https://github.com/YOUR_USERNAME/PrivateDeploy.git

# Add all files
git add .

# Commit
git commit -m "feat: add GitHub Actions CI/CD workflows"

# Push to GitHub
git push -u origin main
```

### 2. Check Build Status

After pushing, visit the GitHub repository page:
```
https://github.com/YOUR_USERNAME/PrivateDeploy/actions
```

You will see the automatically triggered workflows start running.

### 3. Download Build Artifacts

After the build completes, find the corresponding workflow run in the Actions page. Click into it to download:
- Android APK (debug/release)
- Android App Bundle (AAB)
- iOS IPA
- Go Mobile AAR/Framework

---

## 🔧 Workflow Overview

The project includes 5 main GitHub Actions workflows:

### 1. **CI - Continuous Integration** (`ci.yml`)

**Trigger conditions:**
- Push to `main`, `develop`, `feature/*` branches
- Pull Request targeting `main`, `develop`
- Automatically runs daily at 2 AM (scheduled task)
- Manual trigger

**Tasks executed:**
```
1. Lint Check (code check)
   ├─ Flutter analyze
   └─ Dart format check

2. Unit Tests (unit tests)
   ├─ Run tests with coverage
   └─ Upload coverage to Codecov

3. Build Android (build Android)
   ├─ Build Go Mobile AAR
   └─ Build Debug APK

4. Build Web (build Web)
   └─ Build Web release

5. Security Scan (security scan)
   └─ Trivy vulnerability scan
```

**Build time:** about 15-20 minutes

---

### 2. **Build Android** (`build-android.yml`)

**Trigger conditions:**
- Push to `main`, `develop` branches
- Pull Request
- Manual trigger

**Execution steps:**
```
Job 1: Build Go Mobile AAR
  ├─ Setup Go 1.21
  ├─ Setup Android SDK
  ├─ Install gomobile
  ├─ Run build-android.sh
  └─ Upload AAR artifact

Job 2: Build Release APK
  ├─ Download AAR from Job 1
  ├─ Setup Flutter 3.16.0
  ├─ Run code generation
  ├─ Build APK (release)
  ├─ Build AAB (release)
  └─ Upload artifacts

Job 3: Build Debug APK
  ├─ Download AAR from Job 1
  ├─ Setup Flutter 3.16.0
  ├─ Build APK (debug)
  └─ Upload artifact
```

**Build artifacts:**
- `vpncore.aar` (Go Mobile AAR)
- `app-release.apk` (Android APK)
- `app-release.aab` (Android App Bundle)
- `app-debug.apk` (Debug APK)

**Build time:** about 25-30 minutes

---

### 3. **Build iOS** (`build-ios.yml`)

**Trigger conditions:**
- Push to `main`, `develop` branches
- Pull Request
- Manual trigger

**Execution steps:**
```
Job 1: Build Go Mobile Framework
  ├─ Setup Go 1.21 (macOS)
  ├─ Install gomobile
  ├─ Run build-ios.sh
  └─ Upload Framework artifact

Job 2: Build iOS IPA
  ├─ Download Framework from Job 1
  ├─ Setup Flutter 3.16.0
  ├─ Build iOS (no codesign)
  ├─ Create IPA package
  └─ Upload IPA artifact

Job 3: Build iOS Simulator
  ├─ Download Framework from Job 1
  ├─ Setup Flutter 3.16.0
  ├─ Build for simulator
  └─ Upload simulator build
```

**Build artifacts:**
- `VPNCore.framework` (Go Mobile Framework)
- `app-release.ipa` (iOS IPA, unsigned)
- `Runner.app` (Simulator build)

**Build time:** about 20-25 minutes

**Note:** The iOS IPA is unsigned and must be signed manually before it can be installed on a real device.

---

### 4. **Test and Analyze** (`test.yml`)

**Trigger conditions:**
- Push to `main`, `develop` branches
- Pull Request
- Manual trigger

**Tasks executed:**
```
1. Flutter Analyze
   ├─ Code analysis
   └─ Format checking

2. Flutter Test
   ├─ Run all tests
   ├─ Generate coverage
   └─ Upload to Codecov

3. Integration Tests (macOS)
   ├─ Start iOS Simulator
   ├─ Run integration tests
   └─ Shutdown simulator

4. Code Quality
   ├─ Check outdated packages
   ├─ Check unused files
   └─ Security audit
```

**Build time:** about 10-15 minutes

---

### 5. **Release Build** (`release.yml`)

**Trigger conditions:**
- Push a tag (format: `v*`, e.g. `v1.0.0`)
- Manual trigger (requires entering a version number)

**Execution steps:**
```
Job 1: Create GitHub Release
  └─ Create release with tag

Job 2: Build Android Release
  ├─ Build Go Mobile AAR
  ├─ Build APK & AAB
  ├─ Rename with version
  └─ Upload to GitHub Release

Job 3: Build iOS Release
  ├─ Build Go Mobile Framework
  ├─ Build IPA
  ├─ Rename with version
  └─ Upload to GitHub Release
```

**Release artifacts:**
- `privatedeploy-v1.0.0.apk`
- `privatedeploy-v1.0.0.aab`
- `privatedeploy-v1.0.0.ipa`

**Build time:** about 35-40 minutes

---

## 🎯 Trigger Methods

### 1. Automatic Triggers

**Push code:**
```bash
git add .
git commit -m "feat: add new feature"
git push origin main
```
This automatically triggers the CI and build workflows.

**Create a Pull Request:**
Create a PR on the GitHub web interface, which automatically triggers the test and build workflows.

**Scheduled task:**
The CI workflow runs automatically every day at 2 AM (UTC time).

### 2. Manual Trigger

Visit the GitHub Actions page:
```
https://github.com/YOUR_USERNAME/PrivateDeploy/actions
```

Select the workflow you want to run and click the **Run workflow** button.

### 3. Release a New Version

**Method 1: Create a Git Tag**
```bash
# Create tag
git tag v1.0.0

# Push tag
git push origin v1.0.0
```

**Method 2: GitHub Release**
1. Visit the repository's Releases page
2. Click "Draft a new release"
3. Create a new tag (e.g. v1.0.0)
4. Fill in the release notes
5. Click "Publish release"

**Method 3: Manual Trigger**
1. Visit the Actions page
2. Select the "Release Build" workflow
3. Click "Run workflow"
4. Enter the version number (e.g. 1.0.0)
5. Click "Run workflow"

---

## 📦 Build Artifacts

### Download Methods

**Method 1: GitHub Actions Artifacts**
1. Visit the Actions page
2. Click the specific workflow run
3. Scroll to the "Artifacts" section at the bottom
4. Click to download the desired file

**Method 2: GitHub Releases**
1. Visit the Releases page
2. Find the corresponding version
3. Download the file in the "Assets" section

### Artifact Description

| File Name | Size | Purpose | Platform |
|--------|------|------|------|
| `app-release.apk` | ~50MB | Direct install | Android |
| `app-release.aab` | ~45MB | Google Play release | Android |
| `app-debug.apk` | ~55MB | Debugging/testing | Android |
| `app-release.ipa` | ~60MB | Install after signing | iOS |
| `vpncore.aar` | ~15MB | Android dependency library | Android |
| `VPNCore.framework` | ~20MB | iOS dependency library | iOS |

### Retention Time

| Build Type | Retention Time |
|---------|---------|
| CI build | 3 days |
| Development build | 7 days |
| Release build | 30 days |
| GitHub Release | Permanent |

---

## 🎉 Release Process

### Standard Release Process

```bash
# 1. Make sure code is committed
git status

# 2. Update the version number
# Edit the version in pubspec.yaml

# 3. Commit the version change
git add pubspec.yaml
git commit -m "chore: bump version to 1.0.0"
git push origin main

# 4. Create and push the tag
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# 5. Wait for GitHub Actions to finish building (about 35-40 minutes)

# 6. Visit the Releases page to verify
# https://github.com/YOUR_USERNAME/PrivateDeploy/releases
```

### Release Checklist

Before releasing, ensure:
- [ ] All tests pass
- [ ] Code has been reviewed
- [ ] Version number has been updated
- [ ] CHANGELOG has been updated
- [ ] Documentation has been updated
- [ ] Tested on a real device
- [ ] Signed (if releasing to an app store)

---

## 🔍 Monitoring and Debugging

### View Build Logs

1. Visit the Actions page
2. Click the workflow run
3. Click the specific Job
4. View the detailed log output

### Common Statuses

| Status | Description |
|------|------|
| ✅ Success | Build succeeded |
| ❌ Failure | Build failed, check the logs |
| 🟡 In Progress | Building |
| ⏸️ Queued | Waiting in queue |
| 🚫 Cancelled | Cancelled |

### Handling Build Failures

**Step 1: View the error logs**
Click the failed Job and look at the red error messages.

**Step 2: Reproduce locally**
Try running the failed commands locally:
```bash
flutter pub get
flutter pub run build_runner build
flutter analyze
flutter test
```

**Step 3: Fix the problem**
Fix the code based on the error messages.

**Step 4: Re-trigger**
Push the fixed code, or click "Re-run jobs".

---

## ⚙️ Custom Configuration

### Change the Flutter Version

Edit the following in the workflow file:
```yaml
- name: Setup Flutter
  uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.16.0'  # Change to the desired version
    channel: 'stable'
```

### Change the Go Version

```yaml
- name: Setup Go
  uses: actions/setup-go@v5
  with:
    go-version: '1.21'  # Change to the desired version
```

### Add Environment Variables

Add to the workflow file:
```yaml
env:
  CUSTOM_VAR: value

steps:
  - name: Use variable
    run: echo $CUSTOM_VAR
```

### Add Secrets

In the GitHub repository settings:
1. Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Add the name and value

Use in the workflow:
```yaml
env:
  API_KEY: ${{ secrets.API_KEY }}
```

---

## 🐛 Troubleshooting

### Issue 1: Android NDK Not Found

**Error:**
```
Error: ANDROID_NDK_HOME environment variable not set
```

**Solution:**
Make sure the `android-actions/setup-android@v3` action is used; it automatically sets up the NDK.

---

### Issue 2: gomobile Initialization Failed

**Error:**
```
gomobile: command not found
```

**Solution:**
Check that it is installed correctly:
```yaml
- name: Install gomobile
  run: |
    go install golang.org/x/mobile/cmd/gomobile@latest
    gomobile init
```

---

### Issue 3: Flutter Code Generation Failed

**Error:**
```
Could not resolve annotation
```

**Solution:**
Run `flutter pub get` first, then run code generation:
```yaml
- name: Get dependencies
  run: flutter pub get

- name: Run code generation
  run: flutter pub run build_runner build --delete-conflicting-outputs
```

---

### Issue 4: iOS Build Fails on macOS

**Error:**
```
xcodebuild: error: Unable to find a destination
```

**Solution:**
Use the `--no-codesign` option:
```bash
flutter build ios --release --no-codesign
```

---

### Issue 5: Artifact Download Failed

**Error:**
```
Unable to download artifact
```

**Solution:**
1. Check that the artifact name is correct
2. Make sure upload and download are in different jobs
3. Use `needs:` to ensure the dependency relationship

---

## 📊 Build Statistics

### Average Build Time

| Workflow | Ubuntu | macOS | Total |
|--------|--------|-------|------|
| CI | 15 min | - | 15 min |
| Android | 25 min | - | 25 min |
| iOS | - | 20 min | 20 min |
| Release | 20 min | 15 min | 35 min |

### Resource Usage

- **Concurrent jobs**: up to 20 (GitHub Free tier)
- **Storage**: Artifacts up to 500MB (cleaned up automatically)
- **Build minutes**: 2000 minutes/month (GitHub Free tier)

---

## 📚 References

### GitHub Actions Documentation
- [GitHub Actions Official Documentation](https://docs.github.com/en/actions)
- [Flutter Action](https://github.com/marketplace/actions/flutter-action)
- [Setup Go](https://github.com/marketplace/actions/setup-go-environment)
- [Setup Android](https://github.com/marketplace/actions/setup-android)

### Flutter Build Documentation
- [Flutter Build and Release an Android App](https://docs.flutter.dev/deployment/android)
- [Flutter Build and Release an iOS App](https://docs.flutter.dev/deployment/ios)

### Go Mobile Documentation
- [gomobile Official Documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

---

## ✅ Best Practices

### 1. Branch Strategy

```
main (production)
  ↑
develop (development)
  ↑
feature/* (feature branches)
```

- `main`: stable version, each push triggers a full build
- `develop`: development version, each push triggers CI
- `feature/*`: feature branches, tests are triggered when a PR is created

### 2. Version Number Convention

Use semantic versioning:
```
v<major>.<minor>.<patch>

For example:
v1.0.0 - first release
v1.1.0 - new feature
v1.1.1 - bug fix
v2.0.0 - major update
```

### 3. Commit Convention

```
feat: new feature
fix: bug fix
docs: documentation update
style: code formatting
refactor: refactoring
test: tests
chore: build/toolchain

For example:
feat: add VPN connection feature
fix: resolve memory leak in profile provider
docs: update README with installation guide
```

### 4. Cache Optimization

The workflows are already configured with caching:
- Flutter SDK cache
- Gradle cache
- Go modules cache

This can significantly speed up builds (about 30-40%).

---

## 🎓 Advanced Usage

### Matrix Builds

Build multiple versions at the same time:
```yaml
strategy:
  matrix:
    flutter-version: ['3.13.0', '3.16.0']
    os: [ubuntu-latest, macos-latest]

steps:
  - uses: subosito/flutter-action@v2
    with:
      flutter-version: ${{ matrix.flutter-version }}
```

### Conditional Execution

Execute only under specific conditions:
```yaml
- name: Deploy to Production
  if: github.ref == 'refs/heads/main'
  run: ./deploy.sh
```

### Scheduled Cleanup

Automatically clean up old artifacts:
```yaml
- name: Delete old artifacts
  uses: c-hive/gha-remove-artifacts@v1
  with:
    age: '7 days'
    skip-recent: 3
```

---

## 📞 Getting Help

If you run into problems:

1. **View logs**: Actions → specific run → view detailed logs
2. **Search issues**: search for similar problems in GitHub Issues
3. **Submit an Issue**: describe the problem, attach logs and environment information
4. **Refer to documentation**: see this document and the official documentation

---

**Document version**: 1.0.0
**Last updated**: 2025-11-05
**Maintainer**: PrivateDeploy Team
