# PrivateDeploy Mobile Development Plan

**English** | [中文](MOBILE_DEVELOPMENT_PLAN.zh-CN.md)

## 📋 Project Overview

**Goal:** Develop Android and iOS mobile apps with the **full feature set** of the desktop version

**Architecture strategy:** Hybrid approach
- **Desktop:** Keep Wails (Windows/macOS/Linux)
- **Mobile:** Build a new Flutter app (Android/iOS)
- **Backend:** Shared Go REST API service

---

## 🎯 Current Feature Inventory (to be implemented on mobile)

### Core Feature Modules

| Module | Feature Description | Mobile Implementation Difficulty |
|------|----------|--------------|
| **HomeView** | Overview dashboard, status display | ⭐ Easy |
| **CloudView** | Cloud server management (Vultr/DigitalOcean) | ⭐⭐ Medium |
| **ProfilesView** | Profile management (DNS/routing/inbound/outbound) | ⭐⭐⭐ Complex |
| **SubscribesView** | Subscription management | ⭐⭐ Medium |
| **RulesetsView** | Ruleset management | ⭐⭐ Medium |
| **PluginsView** | Plugin system | ⭐⭐⭐ Complex |
| **ScheduledTasksView** | Scheduled tasks | ⭐⭐ Medium |
| **SettingsView** | App settings | ⭐ Easy |
| **System Tray** | Background operation, quick switching | ⭐⭐⭐ Requires special handling on mobile |
| **VPN/Proxy Core** | sing-box integration | ⭐⭐⭐⭐ Most complex |

### Backend Features

- ✅ Cloud provider management (Vultr, DigitalOcean)
- ✅ Server CRUD operations
- ✅ Region/plan queries
- ✅ Profile management
- ✅ Network interface queries
- ✅ Notification system
- ✅ File I/O operations
- ✅ Process management
- ✅ MMDB geolocation

---

## 🔧 Technology Selection Analysis

### Option Comparison

| Tech Stack | Pros | Cons | Recommendation |
|--------|------|------|--------|
| **Flutter** | • Single codebase for both platforms<br>• Performance close to native<br>• Rich UI components<br>• Good Go integration (gomobile) | • Larger package size (~20MB) | ⭐⭐⭐⭐⭐ **Strongly recommended** |
| **React Native** | • Web tech stack<br>• Frontend can reuse some code<br>• Large community | • Difficult Go integration<br>• Requires Native Module bridging | ⭐⭐⭐ Optional |
| **Kotlin Multiplatform** | • Pure native performance<br>• Type safety | • Requires separate Android/iOS development<br>• Steep learning curve | ⭐⭐ Not recommended |

### ✅ Final Choice: **Flutter**

**Reasons:**
1. **Go integration** - Go code can be compiled into a mobile library with `gomobile`
2. **Performance** - Close to native performance, suitable for VPN apps
3. **Development efficiency** - Single codebase supports both Android and iOS
4. **sing-box support** - sing-box has official mobile integration examples

---

## 🏗️ New Architecture Design

### Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│                    Client Layer                      │
├──────────────────┬──────────────────────────────────┤
│  Desktop Client   │         Mobile Client            │
│  (Wails)         │         (Flutter)                │
│                  │                                   │
│  • Windows       │  • Android 7.0+                  │
│  • macOS         │  • iOS 12.0+                     │
│  • Linux         │                                   │
└──────────────────┴──────────────────────────────────┘
         │                          │
         │                          │
         ▼                          ▼
┌─────────────────────────────────────────────────────┐
│              REST API Server (Go)                    │
│                                                      │
│  • HTTP/HTTPS interface                              │
│  • JWT authentication                                │
│  • WebSocket real-time notifications                 │
│  • Cloud provider integration                        │
│  • Configuration management                          │
│  • Data persistence                                  │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│              Data Storage Layer                      │
│                                                      │
│  • SQLite (local)                                   │
│  • File system (config/logs)                         │
└─────────────────────────────────────────────────────┘
```

---

## 📱 Mobile-Specific Feature Implementation

### 1. VPN Core Feature (most critical)

#### Android Implementation
```dart
// Use Android VpnService
class SingBoxVpnService {
  // Call the Go sing-box library via Platform Channel
  static const platform = MethodChannel('com.privatedeploy/vpn');

  Future<void> startVpn(String configPath) async {
    await platform.invokeMethod('startVpn', {'config': configPath});
  }

  Future<void> stopVpn() async {
    await platform.invokeMethod('stopVpn');
  }
}
```

**Implementation approach:**
- Compile Go sing-box into an `.aar` library via `gomobile`
- Android VpnService calls the Go library
- Requires requesting the `BIND_VPN_SERVICE` permission

#### iOS Implementation
```dart
// Use Network Extension
class SingBoxNetworkExtension {
  // Call the Go sing-box library via Platform Channel
  Future<void> startTunnel(String configPath) async {
    await platform.invokeMethod('startTunnel', {'config': configPath});
  }
}
```

**Implementation approach:**
- Compile Go sing-box into a `.framework` via `gomobile`
- Use Network Extension (NEPacketTunnelProvider)
- Requires requesting Network Extension permission

### 2. Background Operation

#### Android
- Use Foreground Service (persistent notification)
- WorkManager scheduled tasks
- Battery optimization whitelist guidance

#### iOS
- Background Modes (VPN automatically stays in the background)
- Silent Push Notifications
- App Refresh

### 3. System Tray Alternatives

Mobile has no system tray, so the following approaches are used:

- ✅ **Quick Settings Tile** (Android Quick Settings Tile)
- ✅ **Persistent notification** (shows connection status)
- ✅ **Widget** (iOS 14+, Android)
- ✅ **3D Touch / Haptic Touch quick menu** (iOS)

---

## 🚀 Development Roadmap

### Phase 1: Foundation Architecture (4-6 weeks)

**Week 1-2: Backend API service**
- [ ] Refactor existing Go code into a standalone HTTP service
- [ ] Implement JWT authentication
- [ ] Design RESTful API interfaces
- [ ] WebSocket real-time notifications
- [ ] API documentation (Swagger)

**Week 3-4: Flutter project initialization**
- [ ] Create Flutter project structure
- [ ] Configure Android/iOS build environments
- [ ] Integrate sing-box Go library (gomobile)
- [ ] Implement basic VPN functionality (Android VpnService)
- [ ] Implement basic VPN functionality (iOS Network Extension)

**Week 5-6: Core feature development**
- [ ] UI framework (Material Design / Cupertino)
- [ ] State management (Provider / Riverpod / Bloc)
- [ ] Network request layer (Dio + Retrofit)
- [ ] Local storage (Hive / SQLite)

### Phase 2: Feature Implementation (8-10 weeks)

**Week 7-8: Home & connection management**
- [ ] HomeView - dashboard UI
- [ ] Connection status display
- [ ] One-tap connect/disconnect
- [ ] Traffic statistics charts
- [ ] Latency testing

**Week 9-10: Cloud server management**
- [ ] CloudView - server list
- [ ] Create server wizard
- [ ] Region/plan selector
- [ ] Server details page
- [ ] Destroy server confirmation

**Week 11-12: Configuration management**
- [ ] ProfilesView - configuration list
- [ ] Configuration editor (simplified JSON)
- [ ] Inbound/outbound configuration
- [ ] DNS configuration
- [ ] Routing rule configuration

**Week 13-14: Subscriptions & rulesets**
- [ ] SubscribesView - subscription management
- [ ] Subscription update/import
- [ ] RulesetsView - ruleset management
- [ ] Rule editor

**Week 15-16: Advanced features**
- [ ] PluginsView - plugin system
- [ ] ScheduledTasksView - scheduled tasks
- [ ] SettingsView - app settings
- [ ] CommandView - command-line interface (optional)

### Phase 3: Mobile Optimization (4 weeks)

**Week 17-18: Platform features**
- [ ] Android Quick Settings Tile
- [ ] iOS Widget (Today Extension)
- [ ] 3D Touch quick menu
- [ ] Notification management
- [ ] Share extension (import configuration)

**Week 19-20: Performance optimization**
- [ ] Network optimization (HTTP/2, connection pooling)
- [ ] Memory optimization
- [ ] Battery optimization
- [ ] Startup speed optimization
- [ ] Package size optimization

### Phase 4: Testing & Release (4 weeks)

**Week 21-22: Testing**
- [ ] Unit tests
- [ ] Integration tests
- [ ] UI automation tests
- [ ] Beta testing (TestFlight / Google Play Beta)
- [ ] Bug fixes

**Week 23-24: Release preparation**
- [ ] App store screenshots
- [ ] App description copy
- [ ] Privacy policy
- [ ] Google Play listing
- [ ] App Store review submission

---

## 📦 Detailed Tech Stack Inventory

### Mobile (Flutter)

```yaml
dependencies:
  # Core
  flutter:
    sdk: flutter

  # UI components
  flutter_screenutil: ^5.9.0  # Screen adaptation
  flutter_svg: ^2.0.9          # SVG icons

  # State management
  provider: ^6.1.1             # Or riverpod / bloc

  # Networking
  dio: ^5.4.0                  # HTTP client
  retrofit: ^4.0.3             # REST API
  web_socket_channel: ^2.4.0   # WebSocket

  # Local storage
  hive: ^2.2.3                 # NoSQL database
  hive_flutter: ^1.1.0
  shared_preferences: ^2.2.2   # Key-Value storage

  # VPN core
  flutter_vpn: ^1.0.0          # network service wrapper

  # Charts
  fl_chart: ^0.66.0            # Traffic statistics charts

  # Utilities
  intl: ^0.18.1                # Internationalization
  logger: ^2.0.2               # Logging
  path_provider: ^2.1.1        # File paths
  permission_handler: ^11.1.0  # Permission management

  # Others
  flutter_local_notifications: ^16.3.0  # Local notifications
  package_info_plus: ^5.0.1             # App information
```

### Backend (Go REST API)

```go
// Main dependencies
require (
    github.com/gin-gonic/gin v1.10.0           // Web framework
    github.com/golang-jwt/jwt/v5 v5.2.0        // JWT authentication
    github.com/gorilla/websocket v1.5.1        // WebSocket
    gorm.io/gorm v1.25.5                       // ORM
    gorm.io/driver/sqlite v1.5.4               // SQLite
    github.com/swaggo/swag v1.16.2             // API documentation
    github.com/sagernet/sing-box v1.8.0        // VPN core
)
```

---

## 🔐 Security Considerations

### API Security
- ✅ JWT Token authentication
- ✅ HTTPS encrypted transport
- ✅ API Rate Limiting
- ✅ Request signature verification

### Mobile Security
- ✅ Key storage (Keychain / KeyStore)
- ✅ SSL Pinning (protects against man-in-the-middle attacks)
- ✅ Code obfuscation (R8 / Obfuscation)
- ✅ Root/jailbreak detection

### VPN Security
- ✅ Configuration file encryption
- ✅ DNS leak protection
- ✅ IPv6 leak protection
- ✅ Kill Switch (network kill protection)

---

## 📊 Estimated Effort

| Phase | Effort | Staffing |
|------|--------|----------|
| **Phase 1: Foundation Architecture** | 6 weeks | 1 Go backend + 1 Flutter developer |
| **Phase 2: Feature Implementation** | 10 weeks | 2 Flutter developers + 1 Go backend |
| **Phase 3: Mobile Optimization** | 4 weeks | 2 Flutter developers |
| **Phase 4: Testing & Release** | 4 weeks | Everyone |
| **Total** | **24 weeks (6 months)** | **2-3 people** |

---

## 💰 Cost Estimate

### Development Costs
- **Staffing cost:** 2-3 developers × 6 months
- **Development tools:** Android Studio, Xcode, GitHub (free or existing)

### Infrastructure
- **API server:** Cloud server $10-50/month
- **CDN/storage:** $5-20/month
- **Test devices:** Android test phone, iPhone test phone

### App Stores
- **Google Play:** $25 one-time registration fee
- **App Store:** $99/year

---

## 🎯 MVP (Minimum Viable Product) Recommendation

If you want quick validation, you can first implement the **MVP version** (3 months):

### MVP Core Features
1. ✅ Basic VPN connection (single profile)
2. ✅ Cloud server management (Vultr only)
3. ✅ Profile import/export
4. ✅ Connection status display
5. ✅ Basic settings

### MVP Excluded Features
- ❌ Plugin system
- ❌ Scheduled tasks
- ❌ Advanced routing rules
- ❌ Ruleset editor
- ❌ Command-line interface

---

## 📝 Next Steps

### Can be done immediately:
1. **Decision confirmation** - Confirm adopting the Flutter approach
2. **Environment setup** - Install Flutter SDK, Android Studio, Xcode
3. **Prototype design** - UI/UX design mockups (Figma)
4. **API design** - Write API interface documentation

### This week's tasks:
1. **Create Flutter project** - `flutter create privatedeploy_mobile`
2. **Configure build environment** - Android/iOS signing configuration
3. **Set up Go REST API** - Refactor the bridge code

### This month's goals:
1. **Complete Phase 1** - Foundation architecture set up
2. **Demo** - Able to start a VPN connection on a phone

---

## 📚 Reference Resources

### Flutter VPN Development
- [sing-box Android example](https://github.com/SagerNet/sing-box-for-android)
- [Flutter VPN Plugin](https://pub.dev/packages/flutter_vpn)
- [gomobile documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

### API Design
- [REST API Best Practices](https://restfulapi.net/)
- [JWT Authentication Guide](https://jwt.io/introduction)

### UI/UX References
- [Clash for Android](https://github.com/Kr328/ClashForAndroid)
- [V2rayNG](https://github.com/2dust/v2rayNG)
- [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)

---

## ✅ Success Criteria

Criteria for completed mobile development:

- ✅ Supports Android 7.0+ and iOS 12.0+
- ✅ 100% feature parity with the desktop version
- ✅ Startup time < 3 seconds
- ✅ Memory usage < 100MB (idle state)
- ✅ Reasonable battery consumption (< 5% over 24 hours in the background)
- ✅ Network latency increase < 50ms
- ✅ User rating > 4.0 stars
- ✅ Crash rate < 0.5%

---

**Document version:** v1.0
**Created:** 2025-11-04
**Next update:** Weekly after development starts
