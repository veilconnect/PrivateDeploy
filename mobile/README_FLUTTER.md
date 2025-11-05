# PrivateDeploy Mobile

Flutter 移动端应用 - 跨平台 VPN 管理客户端

## 📱 支持平台

- Android 5.0+ (API 21+)
- iOS 12.0+

## 🚀 快速开始

### 安装依赖

```bash
flutter pub get
```

### 生成代码

```bash
# 生成 Retrofit API 客户端代码
flutter pub run build_runner build --delete-conflicting-outputs

# 或者监听模式（开发时使用）
flutter pub run build_runner watch
```

### 运行应用

```bash
# 运行在连接的设备
flutter run

# 运行在特定设备
flutter run -d <device-id>

# 查看可用设备
flutter devices
```

### 构建应用

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release

# iOS
flutter build ios --release
```

## 📁 项目结构

```
lib/
├── main.dart                    # 应用入口
├── core/                        # 核心功能
│   ├── constants/
│   │   └── api_constants.dart   # API 常量
│   ├── network/
│   │   ├── api_client.dart      # Retrofit API 客户端
│   │   └── websocket_service.dart  # WebSocket 服务
│   └── storage/
│       └── storage_service.dart # 本地存储
├── features/                    # 功能模块
│   ├── auth/
│   │   ├── auth_provider.dart   # 认证状态管理
│   │   └── login_screen.dart    # 登录界面
│   ├── home/
│   │   └── home_screen.dart     # 主页
│   └── cloud/
│       ├── cloud_provider.dart  # 云服务状态管理
│       └── cloud_screen.dart    # 云服务器管理界面
└── shared/                      # 共享组件
    ├── utils/
    │   └── logger.dart          # 日志工具
    └── widgets/
        ├── loading_indicator.dart
        ├── error_view.dart
        └── empty_view.dart
```

## 🔧 技术栈

### 核心依赖

- **flutter_screenutil**: 屏幕适配
- **provider**: 状态管理
- **dio**: HTTP 客户端
- **retrofit**: REST API 封装
- **hive**: 本地数据库
- **shared_preferences**: Key-Value 存储
- **logger**: 日志记录
- **web_socket_channel**: WebSocket 支持

### UI 组件

- **flutter_svg**: SVG 图标
- **fl_chart**: 图表显示
- **flutter_local_notifications**: 本地通知

### 工具

- **permission_handler**: 权限管理
- **package_info_plus**: 应用信息
- **path_provider**: 文件路径

## 🌐 API 配置

默认 API 地址：`http://localhost:8443/api/v1`

修改 API 地址，编辑：
```dart
// lib/core/constants/api_constants.dart
static const String baseUrl = 'http://your-api-server:8443/api/v1';
```

## 📝 开发说明

### 添加新的 API 端点

1. 在 `api_client.dart` 中添加接口定义：
```dart
@GET("/new/endpoint")
Future<Map<String, dynamic>> getNewData();
```

2. 重新生成代码：
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

### 创建新的 Provider

1. 创建新的 Provider 类继承 `ChangeNotifier`
2. 在 `main.dart` 的 `MultiProvider` 中注册
3. 在界面中使用 `Consumer` 或 `Provider.of` 访问

### 添加新界面

1. 在 `lib/features/` 下创建新模块目录
2. 创建界面文件和 Provider 文件
3. 在导航系统中注册路由

## 🔐 安全注意事项

- Token 存储在加密的 SharedPreferences 中
- 敏感数据不要在日志中输出
- 生产环境使用 HTTPS
- 实现 SSL Pinning（待完成）

## 🧪 测试

```bash
# 运行所有测试
flutter test

# 运行特定测试
flutter test test/features/auth_test.dart

# 生成测试覆盖率
flutter test --coverage
```

## 📦 构建发布版本

### Android

1. 配置签名密钥
2. 构建：
```bash
flutter build appbundle --release
```

### iOS

1. 配置证书和描述文件
2. 构建：
```bash
flutter build ios --release
```

## 🐛 调试

### 查看日志

```bash
flutter logs
```

### 调试模式运行

```bash
flutter run --debug
```

### 性能分析

```bash
flutter run --profile
```

## 📚 相关文档

- [Flutter 官方文档](https://flutter.dev/docs)
- [Provider 文档](https://pub.dev/packages/provider)
- [Dio 文档](https://pub.dev/packages/dio)
- [Retrofit 文档](https://pub.dev/packages/retrofit)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

与 PrivateDeploy 主项目相同
