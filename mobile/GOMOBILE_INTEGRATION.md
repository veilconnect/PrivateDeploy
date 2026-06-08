# GoMobile Integration Guide

**English** | [中文](GOMOBILE_INTEGRATION.zh-CN.md)

This document explains how to integrate the sing-box VPN core into a Flutter mobile application.

## Overview

PrivateDeploy uses sing-box as its VPN core engine. To run sing-box on Android and iOS, the Go code must be compiled into native libraries for mobile platforms via gomobile.

## Architecture Design

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

## Implementation Steps

### Phase 1: Create the Go Mobile Bridge Layer

1. **Create the bridge package** (`~/PrivateDeploy/mobile/gomobile/`)
   - Define the Go interface that Flutter can call
   - Encapsulate the sing-box core functionality
   - Handle configuration file loading and updates

2. **Implement the core interface**
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

3. **Compile the mobile libraries**
   ```bash
   # Android
   gomobile bind -target=android -o mobile/android/libs/vpncore.aar ./gomobile

   # iOS
   gomobile bind -target=ios -o mobile/ios/VPNCore.framework ./gomobile
   ```

### Phase 2: Android Integration

1. **Implement VpnService**
   - Extend `android.net.VpnService`
   - Configure the TUN interface
   - Call the Go bridge layer to start the VPN

2. **Permission configuration** (`AndroidManifest.xml`)
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

3. **Platform Channel implementation**
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

### Phase 3: iOS Integration

1. **Implement the Network Extension**
   - Create the Packet Tunnel Provider
   - Configure routing rules
   - Call the Go bridge layer

2. **Configure Entitlements**
   ```xml
   <key>com.apple.developer.networking.networkextension</key>
   <array>
       <string>packet-tunnel-provider</string>
   </array>
   ```

3. **Platform Channel implementation**
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

### Phase 4: Flutter Interface Layer

1. **Create the Platform Channel**
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

2. **Integrate into VpnProvider**
   - Replace REST API calls with native calls
   - Handle native event callbacks
   - Update the UI state

## Technical Requirements

### Development Environment

- **Go**: 1.21+
- **gomobile**: `go install golang.org/x/mobile/cmd/gomobile@latest`
- **NDK**: Android NDK r25c (for Android)
- **Xcode**: 14+ (for iOS)

### Dependencies

- **sing-box**: VPN core engine
- **golang.org/x/mobile**: gomobile toolchain
- **github.com/sagernet/sing**: network protocol library

## Directory Structure

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

## Data Flow

### Starting the VPN

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

### Traffic Statistics

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

## Security Considerations

1. **Configuration file encryption**: Sensitive configuration (passwords, keys) should be stored encrypted
2. **Communication encryption**: Encrypt data transfers over the Platform Channel
3. **Certificate validation**: Certificate pinning for TLS connections
4. **Memory safety**: Memory management between Go and native code

## Performance Optimization

1. **Reduce cross-language calls**: Transfer data in batches rather than calling frequently
2. **Asynchronous processing**: Use asynchronous methods for VPN operations to avoid blocking the UI
3. **Memory management**: Release objects created by gomobile promptly
4. **Traffic statistics**: Use EventChannel instead of polling

## Debugging Guide

### Android Debugging

```bash
# 查看 VPN 服务日志
adb logcat | grep VpnService

# 查看 Go 代码日志
adb logcat | grep GoLog

# 检查 TUN 接口
adb shell ip addr show tun0
```

### iOS Debugging

```bash
# 查看 Network Extension 日志
log stream --predicate 'process == "VPNExtension"'

# 检查 VPN 配置
networksetup -showpppoestatus "VPN Connection"
```

## FAQ

### Q: gomobile bind compilation fails
**A**: Make sure the NDK and Go environment are configured correctly, and check the `ANDROID_HOME` and `ANDROID_NDK_HOME` environment variables.

### Q: Android VPN won't start
**A**: Check that the VPN permission was requested correctly and that the user has granted it.

### Q: iOS Network Extension crashes
**A**: Check the memory limit (the Extension has only ~30MB), and make sure the Go code does not exceed the limit.

### Q: Poor cross-language call performance
**A**: Reduce the call frequency, use batch data transfer, and enable gomobile's optimization options.

## Next Steps

1. ✅ Complete Flutter UI and REST API integration
2. 📝 Implement the Go Mobile bridge layer (current phase)
3. ⏳ Android VpnService implementation
4. ⏳ iOS Network Extension implementation
5. ⏳ Platform Channel integration
6. ⏳ Full testing and optimization

## References

- [gomobile Official Documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [sing-box Documentation](https://sing-box.sagernet.org/)
- [Android VpnService Guide](https://developer.android.com/guide/topics/connectivity/vpn)
- [iOS Network Extension Programming Guide](https://developer.apple.com/documentation/networkextension)
- [Flutter Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
