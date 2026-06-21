# GitHub Actions 自动化构建指南

本文档详细说明如何使用 GitHub Actions 自动编译和测试 PrivateDeploy Mobile 项目。

---

## 📋 目录

1. [快速开始](#快速开始)
2. [工作流说明](#工作流说明)
3. [触发方式](#触发方式)
4. [构建产物](#构建产物)
5. [发布流程](#发布流程)
6. [故障排除](#故障排除)

---

## 🚀 快速开始

### 1. 推送代码到 GitHub

```bash
cd ~/PrivateDeploy/mobile

# 初始化 Git 仓库（如果还没有）
git init

# 添加远程仓库
git remote add origin https://github.com/YOUR_USERNAME/PrivateDeploy.git

# 添加所有文件
git add .

# 提交
git commit -m "feat: add GitHub Actions CI/CD workflows"

# 推送到 GitHub
git push -u origin main
```

### 2. 查看构建状态

推送后，访问 GitHub 仓库页面：
```
https://github.com/YOUR_USERNAME/PrivateDeploy/actions
```

你会看到自动触发的工作流开始运行。

### 3. 下载构建产物

构建完成后，在 Actions 页面找到对应的工作流运行记录，点击进入后可以下载：
- Android APK (debug/release)
- Android App Bundle (AAB)
- iOS IPA
- Go Mobile AAR/Framework

---

## 🔧 工作流说明

项目包含 5 个主要的 GitHub Actions 工作流：

### 1. **CI - 持续集成** (`ci.yml`)

**触发条件:**
- 推送到 `main`, `develop`, `feature/*` 分支
- 针对 `main`, `develop` 的 Pull Request
- 每天凌晨 2 点自动运行（定时任务）
- 手动触发

**执行任务:**
```
1. Lint Check (代码检查)
   ├─ Flutter analyze
   └─ Dart format check

2. Unit Tests (单元测试)
   ├─ Run tests with coverage
   └─ Upload coverage to Codecov

3. Build Android (构建 Android)
   ├─ Build Go Mobile AAR
   └─ Build Debug APK

4. Build Web (构建 Web)
   └─ Build Web release

5. Security Scan (安全扫描)
   └─ Trivy vulnerability scan
```

**构建时间:** 约 15-20 分钟

---

### 2. **Build Android** (`build-android.yml`)

**触发条件:**
- 推送到 `main`, `develop` 分支
- Pull Request
- 手动触发

**执行步骤:**
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

**构建产物:**
- `vpncore.aar` (Go Mobile AAR)
- `app-release.apk` (Android APK)
- `app-release.aab` (Android App Bundle)
- `app-debug.apk` (Debug APK)

**构建时间:** 约 25-30 分钟

---

### 3. **Build iOS** (`build-ios.yml`)

**触发条件:**
- 推送到 `main`, `develop` 分支
- Pull Request
- 手动触发

**执行步骤:**
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

**构建产物:**
- `VPNCore.framework` (Go Mobile Framework)
- `app-release.ipa` (iOS IPA, 未签名)
- `Runner.app` (Simulator build)

**构建时间:** 约 20-25 分钟

**注意:** iOS IPA 未签名，需要手动签名后才能安装到真机。

---

### 4. **Test and Analyze** (`test.yml`)

**触发条件:**
- 推送到 `main`, `develop` 分支
- Pull Request
- 手动触发

**执行任务:**
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

**构建时间:** 约 10-15 分钟

---

### 5. **Release Build** (`release.yml`)

**触发条件:**
- 推送 tag (格式: `v*`, 例如 `v1.0.0`)
- 手动触发（需要输入版本号）

**执行步骤:**
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

**发布产物:**
- `privatedeploy-v1.0.0.apk`
- `privatedeploy-v1.0.0.aab`
- `privatedeploy-v1.0.0.ipa`

**构建时间:** 约 35-40 分钟

---

## 🎯 触发方式

### 1. 自动触发

**推送代码:**
```bash
git add .
git commit -m "feat: add new feature"
git push origin main
```
这会自动触发 CI 和构建工作流。

**创建 Pull Request:**
在 GitHub 网页上创建 PR，会自动触发测试和构建。

**定时任务:**
CI 工作流每天凌晨 2 点自动运行（UTC 时间）。

### 2. 手动触发

访问 GitHub Actions 页面：
```
https://github.com/YOUR_USERNAME/PrivateDeploy/actions
```

选择要运行的工作流，点击 **Run workflow** 按钮。

### 3. 发布新版本

**方式 1: 创建 Git Tag**
```bash
# 创建 tag
git tag v1.0.0

# 推送 tag
git push origin v1.0.0
```

**方式 2: GitHub Release**
1. 访问仓库的 Releases 页面
2. 点击 "Draft a new release"
3. 创建新的 tag (例如 v1.0.0)
4. 填写发布说明
5. 点击 "Publish release"

**方式 3: 手动触发**
1. 访问 Actions 页面
2. 选择 "Release Build" 工作流
3. 点击 "Run workflow"
4. 输入版本号 (例如 1.0.0)
5. 点击 "Run workflow"

---

## 📦 构建产物

### 下载方式

**方式 1: GitHub Actions Artifacts**
1. 访问 Actions 页面
2. 点击具体的工作流运行
3. 滚动到底部的 "Artifacts" 部分
4. 点击下载所需的文件

**方式 2: GitHub Releases**
1. 访问 Releases 页面
2. 找到对应版本
3. 在 "Assets" 部分下载文件

### 产物说明

| 文件名 | 大小 | 用途 | 平台 |
|--------|------|------|------|
| `app-release.apk` | ~50MB | 直接安装 | Android |
| `app-release.aab` | ~45MB | Google Play 发布 | Android |
| `app-debug.apk` | ~55MB | 调试测试 | Android |
| `app-release.ipa` | ~60MB | 需签名后安装 | iOS |
| `vpncore.aar` | ~15MB | Android 依赖库 | Android |
| `VPNCore.framework` | ~20MB | iOS 依赖库 | iOS |

### 保留时间

| 构建类型 | 保留时间 |
|---------|---------|
| CI 构建 | 3 天 |
| 开发构建 | 7 天 |
| Release 构建 | 30 天 |
| GitHub Release | 永久 |

---

## 🎉 发布流程

### 标准发布流程

```bash
# 1. 确保代码已提交
git status

# 2. 更新版本号
# 编辑 pubspec.yaml 中的 version

# 3. 提交版本变更
git add pubspec.yaml
git commit -m "chore: bump version to 1.0.0"
git push origin main

# 4. 创建并推送 tag
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# 5. 等待 GitHub Actions 完成构建（约 35-40 分钟）

# 6. 访问 Releases 页面验证
# https://github.com/YOUR_USERNAME/PrivateDeploy/releases
```

### 发布检查清单

发布前确保：
- [ ] 所有测试通过
- [ ] 代码已 review
- [ ] 版本号已更新
- [ ] CHANGELOG 已更新
- [ ] 文档已更新
- [ ] 已在真机上测试
- [ ] 已签名（如需发布到应用商店）

---

## 🔍 监控和调试

### 查看构建日志

1. 访问 Actions 页面
2. 点击工作流运行
3. 点击具体的 Job
4. 查看详细日志输出

### 常见状态

| 状态 | 说明 |
|------|------|
| ✅ Success | 构建成功 |
| ❌ Failure | 构建失败，查看日志 |
| 🟡 In Progress | 正在构建 |
| ⏸️ Queued | 排队等待 |
| 🚫 Cancelled | 已取消 |

### 构建失败处理

**步骤 1: 查看错误日志**
点击失败的 Job，查看红色的错误信息。

**步骤 2: 本地复现**
尝试在本地运行失败的命令：
```bash
flutter pub get
flutter pub run build_runner build
flutter analyze
flutter test
```

**步骤 3: 修复问题**
根据错误信息修复代码。

**步骤 4: 重新触发**
推送修复后的代码，或点击 "Re-run jobs"。

---

## ⚙️ 自定义配置

### 修改 Flutter 版本

编辑工作流文件中的：
```yaml
- name: Setup Flutter
  uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.16.0'  # 修改为所需版本
    channel: 'stable'
```

### 修改 Go 版本

```yaml
- name: Setup Go
  uses: actions/setup-go@v5
  with:
    go-version: '1.21'  # 修改为所需版本
```

### 添加环境变量

在工作流文件中添加：
```yaml
env:
  CUSTOM_VAR: value

steps:
  - name: Use variable
    run: echo $CUSTOM_VAR
```

### 添加 Secrets

在 GitHub 仓库设置中：
1. Settings → Secrets and variables → Actions
2. 点击 "New repository secret"
3. 添加名称和值

在工作流中使用：
```yaml
env:
  API_KEY: ${{ secrets.API_KEY }}
```

---

## 🐛 故障排除

### 问题 1: Android NDK 未找到

**错误:**
```
Error: ANDROID_NDK_HOME environment variable not set
```

**解决方案:**
确保使用了 `android-actions/setup-android@v3` action，它会自动设置 NDK。

---

### 问题 2: gomobile 初始化失败

**错误:**
```
gomobile: command not found
```

**解决方案:**
检查是否正确安装：
```yaml
- name: Install gomobile
  run: |
    go install golang.org/x/mobile/cmd/gomobile@latest
    gomobile init
```

---

### 问题 3: Flutter 代码生成失败

**错误:**
```
Could not resolve annotation
```

**解决方案:**
先运行 `flutter pub get`，再运行代码生成：
```yaml
- name: Get dependencies
  run: flutter pub get

- name: Run code generation
  run: flutter pub run build_runner build --delete-conflicting-outputs
```

---

### 问题 4: iOS 构建在 macOS 上失败

**错误:**
```
xcodebuild: error: Unable to find a destination
```

**解决方案:**
使用 `--no-codesign` 选项：
```bash
flutter build ios --release --no-codesign
```

---

### 问题 5: Artifact 下载失败

**错误:**
```
Unable to download artifact
```

**解决方案:**
1. 检查 artifact 名称是否正确
2. 确保 upload 和 download 在不同的 job 中
3. 使用 `needs:` 确保依赖关系

---

## 📊 构建统计

### 平均构建时间

| 工作流 | Ubuntu | macOS | 总计 |
|--------|--------|-------|------|
| CI | 15分钟 | - | 15分钟 |
| Android | 25分钟 | - | 25分钟 |
| iOS | - | 20分钟 | 20分钟 |
| Release | 20分钟 | 15分钟 | 35分钟 |

### 资源使用

- **并发任务**: 最多 20 个（GitHub Free tier）
- **存储**: Artifacts 最多 500MB（会自动清理）
- **构建分钟数**: 2000 分钟/月（GitHub Free tier）

---

## 📚 参考资料

### GitHub Actions 文档
- [GitHub Actions 官方文档](https://docs.github.com/en/actions)
- [Flutter Action](https://github.com/marketplace/actions/flutter-action)
- [Setup Go](https://github.com/marketplace/actions/setup-go-environment)
- [Setup Android](https://github.com/marketplace/actions/setup-android)

### Flutter 构建文档
- [Flutter 构建和发布 Android 应用](https://docs.flutter.dev/deployment/android)
- [Flutter 构建和发布 iOS 应用](https://docs.flutter.dev/deployment/ios)

### Go Mobile 文档
- [gomobile 官方文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

---

## ✅ 最佳实践

### 1. 分支策略

```
main (生产)
  ↑
develop (开发)
  ↑
feature/* (功能分支)
```

- `main`: 稳定版本，每次推送触发完整构建
- `develop`: 开发版本，每次推送触发 CI
- `feature/*`: 功能分支，创建 PR 时触发测试

### 2. 版本号规范

使用语义化版本：
```
v<major>.<minor>.<patch>

例如:
v1.0.0 - 首次发布
v1.1.0 - 新增功能
v1.1.1 - 修复 bug
v2.0.0 - 重大更新
```

### 3. Commit 规范

```
feat: 新功能
fix: 修复 bug
docs: 文档更新
style: 代码格式
refactor: 重构
test: 测试
chore: 构建/工具链

例如:
feat: add VPN connection feature
fix: resolve memory leak in profile provider
docs: update README with installation guide
```

### 4. 缓存优化

工作流已配置缓存：
- Flutter SDK 缓存
- Gradle 缓存
- Go modules 缓存

这可以显著加快构建速度（约 30-40%）。

---

## 🎓 高级用法

### 矩阵构建

同时构建多个版本：
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

### 条件执行

只在特定条件下执行：
```yaml
- name: Deploy to Production
  if: github.ref == 'refs/heads/main'
  run: ./deploy.sh
```

### 定时清理

自动清理旧的 artifacts：
```yaml
- name: Delete old artifacts
  uses: c-hive/gha-remove-artifacts@v1
  with:
    age: '7 days'
    skip-recent: 3
```

---

## 📞 获取帮助

如遇到问题：

1. **查看日志**: Actions → 具体运行 → 查看详细日志
2. **搜索问题**: GitHub Issues 中搜索类似问题
3. **提交 Issue**: 描述问题、附上日志、环境信息
4. **参考文档**: 查看本文档和官方文档

---

**文档版本**: 1.0.0
**最后更新**: 2025-11-05
**维护者**: PrivateDeploy Team
