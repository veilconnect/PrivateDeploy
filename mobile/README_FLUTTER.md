# PrivateDeploy Mobile

**English** | [中文](README_FLUTTER.zh-CN.md)

Flutter mobile app - Cross-platform VPN management client

## 📱 Supported Platforms

- Android 7.0+ (API 24+)
- iOS 12.0+

## 🚀 Quick Start

### Install Dependencies

```bash
flutter pub get
```

### Generate Code

```bash
# Generate Retrofit API client code
flutter pub run build_runner build --delete-conflicting-outputs

# Or watch mode (for development)
flutter pub run build_runner watch
```

### Run the App

```bash
# Run on a connected device
flutter run

# Run on a specific device
flutter run -d <device-id>

# List available devices
flutter devices
```

### Build the App

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release

# iOS
flutter build ios --release
```

## 📁 Project Structure

```
lib/
├── main.dart                    # App entry point
├── core/                        # Core functionality
│   ├── constants/
│   │   └── api_constants.dart   # API constants
│   ├── network/
│   │   ├── api_client.dart      # Retrofit API client
│   │   └── websocket_service.dart  # WebSocket service
│   └── storage/
│       └── storage_service.dart # Local storage
├── features/                    # Feature modules
│   ├── auth/
│   │   ├── auth_provider.dart   # Auth state management
│   │   └── login_screen.dart    # Login screen
│   ├── home/
│   │   └── home_screen.dart     # Home page
│   └── cloud/
│       ├── cloud_provider.dart  # Cloud service state management
│       └── cloud_screen.dart    # Cloud server management screen
└── shared/                      # Shared components
    ├── utils/
    │   └── logger.dart          # Logging utility
    └── widgets/
        ├── loading_indicator.dart
        ├── error_view.dart
        └── empty_view.dart
```

## 🔧 Tech Stack

### Core Dependencies

- **flutter_screenutil**: Screen adaptation
- **provider**: State management
- **dio**: HTTP client
- **retrofit**: REST API wrapper
- **hive**: Local database
- **shared_preferences**: Key-Value storage
- **logger**: Logging
- **web_socket_channel**: WebSocket support

### UI Components

- **flutter_svg**: SVG icons
- **fl_chart**: Chart display
- **flutter_local_notifications**: Local notifications

### Utilities

- **permission_handler**: Permission management
- **package_info_plus**: App information
- **path_provider**: File paths

## 🌐 API Configuration

Default API address: `http://localhost:8443/api/v1`

To change the API address, edit:
```dart
// lib/core/constants/api_constants.dart
static const String baseUrl = 'http://your-api-server:8443/api/v1';
```

## 📝 Development Notes

### Adding a New API Endpoint

1. Add the interface definition in `api_client.dart`:
```dart
@GET("/new/endpoint")
Future<Map<String, dynamic>> getNewData();
```

2. Regenerate the code:
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

### Creating a New Provider

1. Create a new Provider class that extends `ChangeNotifier`
2. Register it in the `MultiProvider` in `main.dart`
3. Access it in the UI using `Consumer` or `Provider.of`

### Adding a New Screen

1. Create a new module directory under `lib/features/`
2. Create the screen file and the Provider file
3. Register the route in the navigation system

## 🔐 Security Considerations

- Tokens are stored in encrypted SharedPreferences
- Do not output sensitive data in logs
- Use HTTPS in production
- Implement SSL Pinning (to be done)

## 🧪 Testing

```bash
# Run all tests
flutter test

# Run a specific test
flutter test test/features/auth_test.dart

# Generate test coverage
flutter test --coverage
```

## 📦 Building Release Versions

### Android

1. Configure the signing key
2. Build:
```bash
flutter build appbundle --release
```

### iOS

1. Configure the certificate and provisioning profile
2. Build:
```bash
flutter build ios --release
```

## 🐛 Debugging

### View Logs

```bash
flutter logs
```

### Run in Debug Mode

```bash
flutter run --debug
```

### Performance Profiling

```bash
flutter run --profile
```

## 📚 Related Documentation

- [Flutter Official Docs](https://flutter.dev/docs)
- [Provider Docs](https://pub.dev/packages/provider)
- [Dio Docs](https://pub.dev/packages/dio)
- [Retrofit Docs](https://pub.dev/packages/retrofit)

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📄 License

Same as the PrivateDeploy main project
