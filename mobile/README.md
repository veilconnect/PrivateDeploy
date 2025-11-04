# PrivateDeploy Mobile App (Flutter)

PrivateDeploy 的移动端应用，支持 Android 和 iOS 平台。

## 📱 功能特性

- ✅ VPN 连接管理
- ✅ 云服务器管理（Vultr/DigitalOcean）
- ✅ 配置文件管理
- ✅ 订阅管理
- ✅ 实时流量统计
- ✅ 规则集管理
- ✅ 多语言支持（中文/英文）

## 🛠️ 技术栈

- **Framework:** Flutter 3.x
- **State Management:** Provider / Riverpod
- **Network:** Dio + Retrofit
- **Storage:** Hive (NoSQL) + SharedPreferences
- **WebSocket:** web_socket_channel
- **VPN Core:** sing-box (via gomobile)

## 📦 环境要求

### 必需

- Flutter SDK 3.19.0+
- Dart 3.3.0+
- Android Studio (for Android)
- Xcode 15.0+ (for iOS, macOS only)

### Android 开发
- Android SDK 21+ (Android 5.0+)
- Java 11+
- Kotlin 1.9+

### iOS 开发
- iOS 12.0+
- CocoaPods
- Swift 5.0+

## 🚀 快速开始

### 1. 安装 Flutter

```bash
# macOS/Linux
git clone https://github.com/flutter/flutter.git -b stable
export PATH="$PATH:`pwd`/flutter/bin"

# 或使用包管理器
# macOS
brew install flutter

# Ubuntu
snap install flutter --classic

# 验证安装
flutter doctor
```

### 2. 创建 Flutter 项目

```bash
cd /home/user/PrivateDeploy
flutter create mobile --org com.privatedeploy --platforms android,ios

# 或使用我们的初始化脚本
./init-mobile.sh
```

### 3. 安装依赖

```bash
cd mobile
flutter pub get
```

### 4. 运行应用

```bash
# Android 模拟器/设备
flutter run

# iOS 模拟器/设备 (macOS only)
flutter run -d ios

# 查看可用设备
flutter devices
```

## 📁 项目结构

```
mobile/
├── android/              # Android 原生代码
├── ios/                  # iOS 原生代码
├── lib/                  # Flutter 代码
│   ├── main.dart         # 应用入口
│   ├── app.dart          # 应用配置
│   ├── core/             # 核心功能
│   │   ├── network/      # 网络层
│   │   │   ├── api_client.dart
│   │   │   ├── dio_client.dart
│   │   │   └── interceptors/
│   │   ├── storage/      # 存储层
│   │   │   ├── hive_service.dart
│   │   │   └── prefs_service.dart
│   │   ├── vpn/          # VPN 核心
│   │   │   ├── vpn_service.dart
│   │   │   └── sing_box_wrapper.dart
│   │   └── constants/    # 常量
│   │       ├── api_constants.dart
│   │       └── app_constants.dart
│   ├── features/         # 功能模块
│   │   ├── auth/         # 认证
│   │   │   ├── data/
│   │   │   ├── domain/
│   │   │   └── presentation/
│   │   ├── home/         # 首页
│   │   ├── cloud/        # 云管理
│   │   ├── profile/      # 配置管理
│   │   ├── subscription/ # 订阅管理
│   │   └── settings/     # 设置
│   └── shared/           # 共享组件
│       ├── widgets/      # 通用组件
│       ├── utils/        # 工具函数
│       └── models/       # 数据模型
├── test/                 # 测试
├── assets/               # 资源文件
│   ├── images/
│   └── i18n/             # 国际化
└── pubspec.yaml          # 依赖配置
```

## 📚 核心依赖

```yaml
dependencies:
  # 核心
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.6

  # UI
  flutter_screenutil: ^5.9.0
  flutter_svg: ^2.0.10

  # 状态管理
  provider: ^6.1.2

  # 网络
  dio: ^5.4.2
  retrofit: ^4.1.0
  web_socket_channel: ^2.4.0

  # 存储
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  shared_preferences: ^2.2.3

  # VPN
  flutter_vpn: ^1.0.0  # 或自定义 Platform Channel

  # 其他
  intl: ^0.18.1
  logger: ^2.3.0
  path_provider: ^2.1.3
  permission_handler: ^11.3.1
```

## 🔧 配置

### API 端点配置

编辑 `lib/core/constants/api_constants.dart`：

```dart
class ApiConstants {
  static const String baseUrl = 'http://10.0.2.2:8443'; // Android 模拟器
  // static const String baseUrl = 'http://localhost:8443'; // iOS 模拟器
  // static const String baseUrl = 'https://your-api.com'; // 生产环境

  static const String wsUrl = 'ws://10.0.2.2:8443/api/v1/ws';
}
```

### Android 权限

编辑 `android/app/src/main/AndroidManifest.xml`：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.BIND_VPN_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

### iOS 权限

编辑 `ios/Runner/Info.plist`：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

添加 Network Extension 权限（需要在 Xcode 中配置）。

## 🧪 测试

```bash
# 运行所有测试
flutter test

# 运行集成测试
flutter drive --target=test_driver/app.dart

# 代码覆盖率
flutter test --coverage
```

## 📦 构建

### Android

```bash
# Debug APK
flutter build apk --debug

# Release APK
flutter build apk --release

# Release Bundle (for Google Play)
flutter build appbundle --release
```

### iOS

```bash
# Debug
flutter build ios --debug

# Release
flutter build ios --release

# 构建 IPA (需要 Xcode)
flutter build ipa --release
```

## 🎯 开发任务

### Phase 1: 基础架构（Week 4-5）
- [ ] Flutter 项目初始化
- [ ] 配置依赖和项目结构
- [ ] 实现 API 客户端
- [ ] 实现本地存储
- [ ] 创建基础 UI 主题

### Phase 2: 核心功能（Week 7-14）
- [ ] 认证功能
- [ ] 首页 UI
- [ ] 云服务器管理
- [ ] 配置文件管理
- [ ] VPN 连接功能

### Phase 3: 高级功能（Week 15-18）
- [ ] 订阅管理
- [ ] 规则集管理
- [ ] 流量统计图表
- [ ] 通知系统
- [ ] 多语言支持

### Phase 4: 优化发布（Week 19-24）
- [ ] 性能优化
- [ ] UI/UX 优化
- [ ] 测试
- [ ] 应用商店上架

## 🐛 常见问题

### Flutter Doctor 报错

```bash
flutter doctor
# 按照提示安装缺失的依赖
```

### Android 许可证问题

```bash
flutter doctor --android-licenses
```

### iOS CocoaPods 问题

```bash
cd ios
pod install
cd ..
```

### 连接 API 服务器失败

- Android 模拟器：使用 `10.0.2.2` 代替 `localhost`
- iOS 模拟器：使用 `localhost` 即可
- 真机：使用电脑的局域网 IP

## 📖 文档

- [Flutter 官方文档](https://flutter.dev/docs)
- [Dart 语言指南](https://dart.dev/guides)
- [Material Design](https://m3.material.io/)
- [Cupertino (iOS)](https://docs.flutter.dev/development/ui/widgets/cupertino)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

与 PrivateDeploy 主项目相同。
