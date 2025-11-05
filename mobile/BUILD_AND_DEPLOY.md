# PrivateDeploy Mobile - 构建和部署指南

本文档提供完整的构建、测试和部署流程。

---

## 📋 目录

1. [开发环境设置](#开发环境设置)
2. [Flutter 项目构建](#flutter-项目构建)
3. [Go Mobile 编译](#go-mobile-编译)
4. [Android 构建和部署](#android-构建和部署)
5. [iOS 构建和部署](#ios-构建和部署)
6. [持续集成](#持续集成)
7. [故障排除](#故障排除)

---

## 🔧 开发环境设置

### 必需工具

#### 1. Flutter SDK

```bash
# 下载 Flutter
git clone https://github.com/flutter/flutter.git -b stable

# 添加到 PATH
export PATH="$PATH:`pwd`/flutter/bin"

# 验证安装
flutter doctor

# 预期输出:
# ✓ Flutter (Channel stable, ...)
# ✓ Android toolchain
# ✓ Xcode (macOS only)
# ✓ VS Code / Android Studio
```

#### 2. Go 环境

```bash
# 安装 Go 1.21+
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz

# 设置环境变量
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# 验证
go version
```

#### 3. gomobile

```bash
# 安装 gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# 初始化
gomobile init

# 验证
gomobile version
```

#### 4. Android SDK 和 NDK

```bash
# 设置环境变量
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653
export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin

# 安装 SDK 组件
sdkmanager "platforms;android-34"
sdkmanager "build-tools;34.0.0"
sdkmanager "ndk;25.2.9519653"
```

#### 5. Xcode (macOS only)

```bash
# 从 App Store 安装 Xcode

# 安装命令行工具
xcode-select --install

# 接受许可
sudo xcodebuild -license accept

# 验证
xcodebuild -version
```

---

## 🎯 Flutter 项目构建

### 1. 获取依赖

```bash
cd /home/user/PrivateDeploy/mobile

# 获取 pub 依赖
flutter pub get

# 生成代码
flutter pub run build_runner build --delete-conflicting-outputs
```

### 2. 代码生成

```bash
# Retrofit API 客户端
flutter pub run build_runner watch

# 或一次性生成
flutter pub run build_runner build --delete-conflicting-outputs
```

### 3. 资源准备

```bash
# 检查资源文件
flutter pub run flutter_launcher_icons:main

# 更新应用图标（如需要）
# 编辑 pubspec.yaml 中的 flutter_icons 配置
```

---

## 🔨 Go Mobile 编译

### Android AAR

```bash
cd gomobile

# 方式 1: 使用脚本
./build-android.sh

# 方式 2: 手动编译
gomobile bind \
    -target=android \
    -androidapi=21 \
    -javapkg="com.privatedeploy.mobile.vpncore" \
    -o=../android/app/libs/vpncore.aar \
    .

# 验证
ls -lh ../android/app/libs/vpncore.aar
```

### iOS Framework

```bash
cd gomobile

# 方式 1: 使用脚本
./build-ios.sh

# 方式 2: 手动编译
gomobile bind \
    -target=ios \
    -iosversion=12.0 \
    -o=../ios/VPNCore.framework \
    .

# 验证
ls -lh ../ios/VPNCore.framework
lipo -info ../ios/VPNCore.framework/VPNCore
```

---

## 📱 Android 构建和部署

### 开发构建

```bash
cd /home/user/PrivateDeploy/mobile

# Debug APK
flutter build apk --debug

# 安装到设备
flutter install

# 或直接运行
flutter run
```

### 发布构建

#### 1. 配置签名

创建 `android/key.properties`:

```properties
storePassword=<your-store-password>
keyPassword=<your-key-password>
keyAlias=privatedeploy
storeFile=<path-to-keystore>
```

修改 `android/app/build.gradle`:

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

#### 2. 构建发布版本

```bash
# 构建 APK
flutter build apk --release

# 构建 App Bundle (推荐用于 Play Store)
flutter build appbundle --release

# 输出位置:
# build/app/outputs/flutter-apk/app-release.apk
# build/app/outputs/bundle/release/app-release.aab
```

#### 3. 测试发布版本

```bash
# 安装 APK
adb install build/app/outputs/flutter-apk/app-release.apk

# 查看日志
adb logcat | grep PrivateDeploy
```

### 部署到 Google Play

#### 1. 准备元数据

- 应用名称: PrivateDeploy
- 包名: com.privatedeploy.mobile
- 版本: 1.0.0
- 类别: 工具
- 隐私政策 URL

#### 2. 创建 Listing

1. 登录 [Google Play Console](https://play.google.com/console)
2. 创建新应用
3. 填写商店信息
4. 上传截图（至少 2 张）
5. 设置内容分级

#### 3. 发布流程

```bash
# 1. 创建内部测试版本
# 上传 app-release.aab 到内部测试

# 2. 封闭测试
# 邀请测试用户，收集反馈

# 3. 开放测试（可选）
# 扩大测试范围

# 4. 正式发布
# 审核通过后发布到生产环境
```

---

## 🍎 iOS 构建和部署

### 开发构建

```bash
# 打开 Xcode 项目
open ios/Runner.xcworkspace

# 或使用 Flutter 命令
flutter run -d <device-id>

# 查看可用设备
flutter devices
```

### 发布构建

#### 1. 配置签名

在 Xcode 中：

1. 选择 **Runner** target
2. 切换到 **Signing & Capabilities**
3. 选择开发团队
4. 配置 Bundle Identifier: `com.privatedeploy.mobile`
5. 启用 **Automatically manage signing**

对 **VPNExtension** target 重复上述步骤。

#### 2. 配置 Capabilities

确保启用：
- ✅ Network Extensions (Packet Tunnel)
- ✅ App Groups
- ✅ Keychain Sharing

#### 3. 构建 IPA

```bash
# 方式 1: Flutter 命令
flutter build ios --release

# 方式 2: Xcode
# Product → Archive
# Organizer → Distribute App

# 方式 3: xcodebuild
cd ios
xcodebuild -workspace Runner.xcworkspace \
           -scheme Runner \
           -configuration Release \
           -archivePath build/Runner.xcarchive \
           archive
```

#### 4. 导出 IPA

```bash
# 使用 xcodebuild
xcodebuild -exportArchive \
           -archivePath build/Runner.xcarchive \
           -exportPath build/ipa \
           -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` 示例:

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

### 部署到 App Store

#### 1. 准备元数据

- 应用名称: PrivateDeploy
- Bundle ID: com.privatedeploy.mobile
- 版本: 1.0.0
- 类别: Utilities
- 隐私政策 URL
- 支持 URL

#### 2. 创建 App Store Connect 记录

1. 登录 [App Store Connect](https://appstoreconnect.apple.com)
2. 创建新应用
3. 填写应用信息
4. 上传截图（iPhone + iPad）
5. 设置年龄分级

#### 3. 上传构建

```bash
# 使用 Xcode Organizer
# 或使用 Transporter.app

# 或使用 altool (命令行)
xcrun altool --upload-app \
             --type ios \
             --file build/ipa/Runner.ipa \
             --username "your-apple-id" \
             --password "@keychain:AC_PASSWORD"
```

#### 4. 提交审核

1. 在 App Store Connect 中选择构建
2. 填写审核信息
3. 提交审核
4. 等待审核结果（通常 1-3 天）

---

## 🔄 持续集成

### GitHub Actions

创建 `.github/workflows/build.yml`:

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

### Fastlane (可选)

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

## 🐛 故障排除

### 常见错误

#### 1. Flutter 依赖问题

```bash
# 清理缓存
flutter clean
flutter pub cache repair

# 重新获取依赖
flutter pub get
```

#### 2. Android 构建失败

```bash
# 清理 Gradle 缓存
cd android
./gradlew clean

# 检查 NDK
echo $ANDROID_NDK_HOME

# 重新构建
cd ..
flutter build apk
```

#### 3. iOS 构建失败

```bash
# 清理构建
cd ios
xcodebuild clean -workspace Runner.xcworkspace -scheme Runner

# 重新获取 Pods
pod deintegrate
pod install

# 重新构建
cd ..
flutter build ios
```

#### 4. gomobile 编译失败

```bash
# 更新 gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# 清理 Go 缓存
go clean -modcache

# 重新编译
cd gomobile
./build-android.sh
```

### 调试技巧

#### Flutter

```bash
# 运行在调试模式
flutter run --debug

# 查看详细日志
flutter run --verbose

# 性能分析
flutter run --profile
```

#### Android

```bash
# 查看日志
adb logcat | grep flutter

# 查看崩溃
adb logcat | grep -i crash

# 查看 VPN
adb logcat | grep VPN
```

#### iOS

```bash
# 查看设备日志
idevicesyslog

# 查看特定应用
idevicesyslog | grep PrivateDeploy

# 使用 Console.app (macOS)
open /System/Applications/Utilities/Console.app
```

---

## ✅ 发布检查清单

### 发布前

- [ ] 所有功能测试通过
- [ ] 单元测试通过
- [ ] UI 测试通过
- [ ] 真机测试通过
- [ ] 性能测试达标
- [ ] 内存泄漏检查
- [ ] 安全审计完成
- [ ] 隐私政策就绪
- [ ] 更新日志编写完成
- [ ] 截图和宣传材料准备好

### Android 特定

- [ ] 签名密钥安全保存
- [ ] ProGuard 规则测试
- [ ] 多设备测试
- [ ] API 21+ 兼容性
- [ ] Play Store 元数据完整

### iOS 特定

- [ ] 证书和描述文件有效
- [ ] Network Extension 测试
- [ ] App Groups 配置正确
- [ ] TestFlight 测试完成
- [ ] App Store 元数据完整
- [ ] 审核准备材料

---

## 📚 参考资料

- [Flutter 构建指南](https://docs.flutter.dev/deployment)
- [Android 发布流程](https://developer.android.com/studio/publish)
- [iOS 发布流程](https://developer.apple.com/ios/submit/)
- [gomobile 文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

---

*最后更新: 2024-11-05*
