# GoMobile Integration Guide

本文档说明如何将 sing-box VPN 核心集成到 Flutter 移动应用中。

## 概述

PrivateDeploy 使用 sing-box 作为 VPN 核心引擎。为了在 Android 和 iOS 上运行 sing-box，需要通过 gomobile 将 Go 代码编译为移动平台的原生库。

## 架构设计

```
┌─────────────────────────────────────────┐
│         Flutter Application             │
│  (Dart: UI + State Management)          │
└────────────┬────────────────────────────┘
             │ Platform Channel
             │ (MethodChannel/EventChannel)
             ▼
┌─────────────────────────────────────────┐
│      Platform Native Code               │
│  ┌──────────────────────────────────┐   │
│  │  Android (Java/Kotlin)           │   │
│  │  - VpnService implementation     │   │
│  │  - Native library loading        │   │
│  └──────────────────────────────────┘   │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │  iOS (Swift/Objective-C)         │   │
│  │  - Network Extension             │   │
│  │  - Native library loading        │   │
│  └──────────────────────────────────┘   │
└────────────┬────────────────────────────┘
             │ JNI/CGO
             ▼
┌─────────────────────────────────────────┐
│      Go Mobile Bridge Library           │
│  (gomobile bind generated)               │
│                                          │
│  - Start/Stop VPN                        │
│  - Update configuration                  │
│  - Get traffic statistics                │
│  - Event callbacks                       │
└────────────┬────────────────────────────┘
             │ Direct function calls
             ▼
┌─────────────────────────────────────────┐
│         sing-box Core                    │
│  (Pure Go VPN implementation)            │
│                                          │
│  - Protocol handlers (SS, Trojan, etc)   │
│  - Routing and DNS                       │
│  - Traffic statistics                    │
└─────────────────────────────────────────┘
```

## 实现步骤

### Phase 1: 创建 Go Mobile 桥接层

1. **创建桥接包** (`~/PrivateDeploy/mobile/gomobile/`)
   - 定义 Flutter 可调用的 Go 接口
   - 封装 sing-box 核心功能
   - 处理配置文件加载和更新

2. **实现核心接口**
   ```go
   // VPNService 接口定义
   type VPNService interface {
       Start(configPath string) error
       Stop() error
       IsRunning() bool
       GetStats() *TrafficStats
       UpdateConfig(config string) error
   }
   ```

3. **编译移动库**
   ```bash
   # Android
   gomobile bind -target=android -o mobile/android/libs/vpncore.aar ./gomobile

   # iOS
   gomobile bind -target=ios -o mobile/ios/VPNCore.framework ./gomobile
   ```

### Phase 2: Android 集成

1. **实现 VpnService**
   - 继承 `android.net.VpnService`
   - 配置 TUN 接口
   - 调用 Go 桥接层启动 VPN

2. **权限配置** (`AndroidManifest.xml`)
   ```xml
   <uses-permission android:name="android.permission.INTERNET" />
   <uses-permission android:name="android.permission.BIND_VPN_SERVICE" />

   <service
       android:name=".VpnService"
       android:permission="android.permission.BIND_VPN_SERVICE">
       <intent-filter>
           <action android:name="android.net.VpnService" />
       </intent-filter>
   </service>
   ```

3. **Platform Channel 实现**
   ```kotlin
   class VpnPlugin : FlutterPlugin, MethodCallHandler {
       override fun onMethodCall(call: MethodCall, result: Result) {
           when (call.method) {
               "startVpn" -> startVpn(call.arguments, result)
               "stopVpn" -> stopVpn(result)
               "getStats" -> getStats(result)
           }
       }
   }
   ```

### Phase 3: iOS 集成

1. **实现 Network Extension**
   - 创建 Packet Tunnel Provider
   - 配置路由规则
   - 调用 Go 桥接层

2. **配置 Entitlements**
   ```xml
   <key>com.apple.developer.networking.networkextension</key>
   <array>
       <string>packet-tunnel-provider</string>
   </array>
   ```

3. **Platform Channel 实现**
   ```swift
   class VpnPlugin: NSObject, FlutterPlugin {
       func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
           switch call.method {
           case "startVpn":
               startVpn(arguments: call.arguments, result: result)
           case "stopVpn":
               stopVpn(result: result)
           default:
               result(FlutterMethodNotImplemented)
           }
       }
   }
   ```

### Phase 4: Flutter 接口层

1. **创建 Platform Channel**
   ```dart
   class VpnNativeService {
       static const platform = MethodChannel('com.privatedeploy.vpn/native');

       Future<bool> startVpn(String config) async {
           try {
               final result = await platform.invokeMethod('startVpn', {
                   'config': config,
               });
               return result as bool;
           } catch (e) {
               return false;
           }
       }
   }
   ```

2. **集成到 VpnProvider**
   - 替换 REST API 调用为原生调用
   - 处理原生事件回调
   - 更新 UI 状态

## 技术要求

### 开发环境

- **Go**: 1.21+
- **gomobile**: `go install golang.org/x/mobile/cmd/gomobile@latest`
- **NDK**: Android NDK r25c (for Android)
- **Xcode**: 14+ (for iOS)

### 依赖库

- **sing-box**: VPN 核心引擎
- **golang.org/x/mobile**: gomobile 工具链
- **github.com/sagernet/sing**: 网络协议库

## 目录结构

```
mobile/
├── gomobile/                    # Go 桥接层代码
│   ├── vpn_service.go          # VPN 服务实现
│   ├── config.go               # 配置管理
│   ├── stats.go                # 统计信息
│   └── callbacks.go            # 事件回调
│
├── android/
│   ├── app/src/main/kotlin/
│   │   └── VpnService.kt       # Android VPN 服务
│   └── libs/
│       └── vpncore.aar         # 编译的 Android 库
│
├── ios/
│   ├── Runner/
│   │   └── VpnPlugin.swift     # iOS VPN 插件
│   ├── VPNExtension/           # Network Extension
│   │   └── PacketTunnelProvider.swift
│   └── Frameworks/
│       └── VPNCore.framework   # 编译的 iOS 框架
│
└── lib/
    └── services/
        └── vpn_native_service.dart  # Flutter 原生桥接
```

## 数据流

### 启动 VPN

```
Flutter (VpnProvider)
    ↓ startVpn()
Platform Channel
    ↓ invokeMethod('startVpn')
Native Code (VpnService/PacketTunnelProvider)
    ↓ VPNCore.Start()
Go Bridge (gomobile)
    ↓ box.Start()
sing-box Core
    ↓ 建立 VPN 连接
```

### 流量统计

```
sing-box Core (每秒更新)
    ↓ 统计数据
Go Bridge (gomobile)
    ↓ GetStats()
Native Code
    ↓ EventChannel.send()
Flutter (VpnProvider)
    ↓ 更新 UI
```

## 安全考虑

1. **配置文件加密**: 敏感配置（密码、密钥）应加密存储
2. **通信加密**: Platform Channel 数据传输加密
3. **证书校验**: TLS 连接的证书 pinning
4. **内存安全**: Go 和 Native 代码间的内存管理

## 性能优化

1. **减少跨语言调用**: 批量传输数据而非频繁调用
2. **异步处理**: VPN 操作使用异步方法避免阻塞 UI
3. **内存管理**: 及时释放 gomobile 创建的对象
4. **流量统计**: 使用 EventChannel 而非轮询

## 调试指南

### Android 调试

```bash
# 查看 VPN 服务日志
adb logcat | grep VpnService

# 查看 Go 代码日志
adb logcat | grep GoLog

# 检查 TUN 接口
adb shell ip addr show tun0
```

### iOS 调试

```bash
# 查看 Network Extension 日志
log stream --predicate 'process == "VPNExtension"'

# 检查 VPN 配置
networksetup -showpppoestatus "VPN Connection"
```

## 常见问题

### Q: gomobile bind 编译失败
**A**: 确保 NDK 和 Go 环境正确配置，检查 `ANDROID_HOME` 和 `ANDROID_NDK_HOME` 环境变量。

### Q: Android VPN 无法启动
**A**: 检查是否正确请求了 VPN 权限，并且用户已授权。

### Q: iOS Network Extension 崩溃
**A**: 检查内存限制（Extension 仅有 ~30MB），确保 Go 代码不会超出限制。

### Q: 跨语言调用性能差
**A**: 减少调用频率，使用批量数据传输，启用 gomobile 的优化选项。

## 下一步

1. ✅ 完成 Flutter UI 和 REST API 集成
2. 📝 实现 Go Mobile 桥接层 (当前阶段)
3. ⏳ Android VpnService 实现
4. ⏳ iOS Network Extension 实现
5. ⏳ Platform Channel 集成
6. ⏳ 完整测试和优化

## 参考资料

- [gomobile 官方文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [sing-box 文档](https://sing-box.sagernet.org/)
- [Android VpnService 指南](https://developer.android.com/guide/topics/connectivity/vpn)
- [iOS Network Extension 编程指南](https://developer.apple.com/documentation/networkextension)
- [Flutter Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
