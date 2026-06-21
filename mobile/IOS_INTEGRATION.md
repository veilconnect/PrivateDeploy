# iOS Go Mobile 集成指南

本文档详细说明如何将 Go Mobile 编译的 Framework 集成到 PrivateDeploy iOS 应用中。

---

## 📋 前提条件

### 开发环境

- **macOS**: Monterey (12.0) 或更高版本
- **Xcode**: 14.0 或更高版本
- **iOS SDK**: iOS 12.0+
- **Go**: 1.21 或更高版本
- **gomobile**: 最新版本
- **CocoaPods**: 1.11.0 或更高版本 (可选)

### Apple Developer Account

- 有效的 Apple Developer 账号
- 已配置的开发证书
- 已启用 Network Extension Capability

---

## 🔧 步骤 1: 编译 Go Mobile 库

### 1.1 安装 gomobile

```bash
# 安装 gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# 初始化 gomobile (需要 Xcode)
gomobile init
```

### 1.2 编译 Framework

```bash
# 进入 gomobile 目录
cd ~/PrivateDeploy/mobile/gomobile

# 运行编译脚本
./build-ios.sh
```

编译成功后，Framework 将生成在：
```
~/PrivateDeploy/mobile/ios/VPNCore.framework
```

### 1.3 验证 Framework

```bash
# 查看支持的架构
lipo -info ios/VPNCore.framework/VPNCore

# 输出应该包含:
# arm64 (真机)
# x86_64 (模拟器, 如果编译时包含)

# 查看导出的符号
nm -g ios/VPNCore.framework/VPNCore | head -20
```

---

## 🔗 步骤 2: 集成到 Xcode 项目

### 2.1 打开 Xcode 项目

```bash
# 打开 workspace (推荐)
open ios/Runner.xcworkspace

# 或打开 project
open ios/Runner.xcodeproj
```

### 2.2 添加 Framework

1. 在 Xcode 中，选择 **Runner** 项目
2. 选择 **Runner** target
3. 切换到 **General** 标签页
4. 滚动到 **Frameworks, Libraries, and Embedded Content**
5. 点击 **+** 按钮
6. 选择 **Add Other...** → **Add Files...**
7. 导航到 `ios/VPNCore.framework`
8. 选择并点击 **Open**
9. 确保设置为 **Embed & Sign**

### 2.3 配置 Build Settings

在 **Build Settings** 中：

```
Framework Search Paths: $(PROJECT_DIR)
```

### 2.4 为 Network Extension 添加 Framework

重复上述步骤为 **VPNExtension** target 添加 Framework：

1. 选择 **VPNExtension** target
2. 添加 `VPNCore.framework`
3. 设置为 **Embed & Sign**

---

## 💻 步骤 3: 在代码中使用 Go 库

### 3.1 导入 Go 包

在 `PacketTunnelProvider.swift` 中：

```swift
import NetworkExtension
import VPNCore

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var vpnCore: VPNCoreVPNService?

    override func startTunnel(options: [String : NSObject]?,
                            completionHandler: @escaping (Error?) -> Void) {
        os_log("[PacketTunnelProvider] Starting tunnel...")

        // 加载配置
        let config = loadConfig()

        // 创建 VPN Core 实例
        do {
            vpnCore = VPNCoreNewVPNService()

            // 启动 VPN
            try vpnCore?.start(config)

            os_log("[PacketTunnelProvider] VPN Core started successfully")
            completionHandler(nil)

        } catch {
            os_log("[PacketTunnelProvider] Failed to start VPN Core: %{public}@",
                   error.localizedDescription)
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        os_log("[PacketTunnelProvider] Stopping tunnel...")

        do {
            try vpnCore?.stop()
            vpnCore = nil

            os_log("[PacketTunnelProvider] VPN Core stopped")

        } catch {
            os_log("[PacketTunnelProvider] Error stopping VPN Core: %{public}@",
                   error.localizedDescription)
        }

        completionHandler()
    }
}
```

### 3.2 处理数据包

```swift
private func startPacketProcessing() {
    packetFlow.readPackets { [weak self] packets, protocols in
        guard let self = self,
              let vpnCore = self.vpnCore else { return }

        do {
            // 处理每个数据包
            for (index, packet) in packets.enumerated() {
                let protocolNumber = protocols[index].intValue

                // 传递给 Go Mobile VPN Core
                try vpnCore.handlePacket(packet, protocolNumber)
            }

            // 继续读取
            self.startPacketProcessing()

        } catch {
            os_log("[PacketTunnelProvider] Error handling packet: %{public}@",
                   error.localizedDescription)
        }
    }
}

// 写入数据包
private func writePackets(_ packets: [Data], protocols: [NSNumber]) {
    guard let vpnCore = vpnCore else { return }

    do {
        // 批量写入
        packetFlow.writePackets(packets, withProtocols: protocols)

    } catch {
        os_log("[PacketTunnelProvider] Error writing packets: %{public}@",
               error.localizedDescription)
    }
}
```

### 3.3 获取流量统计

```swift
private func getStats() -> VPNCoreTrafficStats? {
    guard let vpnCore = vpnCore else { return nil }

    do {
        // 获取 JSON 格式的统计数据
        let statsJSON = try vpnCore.getStats()

        // 解析 JSON
        if let data = statsJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            return VPNCoreTrafficStats(
                uploadBytes: json["upload_bytes"] as? Int64 ?? 0,
                downloadBytes: json["download_bytes"] as? Int64 ?? 0,
                uploadSpeed: json["upload_speed"] as? Int64 ?? 0,
                downloadSpeed: json["download_speed"] as? Int64 ?? 0
            )
        }

    } catch {
        os_log("[PacketTunnelProvider] Error getting stats: %{public}@",
               error.localizedDescription)
    }

    return nil
}
```

---

## 🔐 步骤 4: 配置 Capabilities

### 4.1 启用 Network Extension

1. 选择 **Runner** target
2. 切换到 **Signing & Capabilities** 标签页
3. 点击 **+ Capability**
4. 搜索并添加 **Network Extensions**
5. 勾选 **Packet Tunnel**

### 4.2 配置 App Groups

1. 在 **Capabilities** 中点击 **+ Capability**
2. 添加 **App Groups**
3. 点击 **+** 添加新的 App Group
4. 输入：`group.com.privatedeploy.mobile`
5. 对 **VPNExtension** target 重复上述步骤

### 4.3 配置 Keychain Sharing

1. 添加 **Keychain Sharing** capability
2. 添加 keychain group：`$(AppIdentifierPrefix)com.privatedeploy.mobile`

---

## 🐛 步骤 5: 调试和测试

### 5.1 启用日志

在 Network Extension 中：

```swift
import os.log

let logger = OSLog(subsystem: "com.privatedeploy.mobile.vpnextension",
                   category: "VPN")

os_log("VPN started", log: logger, type: .info)
```

### 5.2 查看日志

使用 Console.app 或命令行：

```bash
# 实时查看日志
log stream --predicate 'process == "VPNExtension"'

# 查看特定子系统
log stream --predicate 'subsystem == "com.privatedeploy.mobile.vpnextension"'
```

### 5.3 调试 Network Extension

**注意**: Network Extension 无法直接在 Xcode 中调试

调试方法：
1. 使用 `os_log` 输出详细日志
2. 将错误信息保存到 App Group 的共享容器
3. 在主应用中读取并显示

```swift
// 写入日志到共享容器
let fileManager = FileManager.default
if let containerURL = fileManager.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.privatedeploy.mobile") {

    let logFile = containerURL.appendingPathComponent("vpn.log")
    try? "VPN started".write(to: logFile, atomically: true, encoding: .utf8)
}
```

### 5.4 测试 VPN 连接

```swift
// 在主应用中测试
let vpnPlugin = VpnPlugin()

// 启动 VPN
let config = """
{
    "log": {"level": "debug"},
    "inbounds": [...],
    "outbounds": [...]
}
"""

let call = FlutterMethodCall(methodName: "startVpn", arguments: ["config": config])
vpnPlugin.handle(call) { result in
    if let success = result as? Bool, success {
        print("VPN started successfully")
    } else {
        print("Failed to start VPN")
    }
}
```

---

## ⚠️ 常见问题

### 问题 1: Framework 未找到

**症状**: Build 失败，提示 `ld: framework not found VPNCore`

**解决方案**:
```bash
# 检查 Framework 是否存在
ls -la ios/VPNCore.framework

# 重新编译
cd gomobile
./build-ios.sh

# 在 Xcode 中检查 Framework Search Paths
# Build Settings → Framework Search Paths → $(PROJECT_DIR)
```

### 问题 2: 符号未找到

**症状**: 运行时错误 `dyld: Symbol not found: _VPNCoreNewVPNService`

**解决方案**:
```swift
// 检查导入
import VPNCore

// 确保 Framework 设置为 Embed & Sign
// 而不是 Do Not Embed
```

### 问题 3: Network Extension 权限错误

**症状**: `NEVPNError: Configuration is invalid`

**解决方案**:
```swift
// 确保在 Capabilities 中启用了:
// - Network Extensions (Packet Tunnel)
// - App Groups

// 检查 Entitlements 文件
// Runner.entitlements 和 VPNExtension.entitlements
```

### 问题 4: Go panic 崩溃

**症状**: Extension 崩溃，Console 显示 Go panic

**解决方案**:
```swift
// 添加错误处理
do {
    try vpnCore?.start(config)
} catch {
    os_log("Go error: %{public}@", error.localizedDescription)
    completionHandler(error)
    return
}
```

### 问题 5: 内存限制

**症状**: Extension 因内存压力被系统终止

**解决方案**:
```swift
// Network Extension 有 ~30MB 内存限制
// 优化内存使用:

// 1. 使用 autoreleasepool
autoreleasepool {
    // 处理数据包
}

// 2. 及时释放大对象
var largeData: Data? = someData
// 使用后
largeData = nil

// 3. 监控内存
let memoryUsage = reportMemory()
os_log("Memory usage: %{public}d MB", memoryUsage)
```

---

## 🔒 安全考虑

### App Transport Security

在 `Info.plist` 中配置（如需要）：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
</dict>
```

### Keychain 访问

```swift
// 使用 Keychain 存储敏感配置
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: "vpn_config",
    kSecAttrAccessGroup as String: "$(AppIdentifierPrefix)com.privatedeploy.mobile",
    kSecValueData as String: configData
]

SecItemAdd(query as CFDictionary, nil)
```

### 数据加密

```swift
// 使用 CryptoKit 加密敏感数据
import CryptoKit

let key = SymmetricKey(size: .bits256)
let encrypted = try AES.GCM.seal(data, using: key)
```

---

## 📊 性能优化

### 1. 批量处理数据包

```swift
private var packetBuffer: [(Data, NSNumber)] = []
private let batchSize = 100

func bufferPacket(_ packet: Data, protocol: NSNumber) {
    packetBuffer.append((packet, `protocol`))

    if packetBuffer.count >= batchSize {
        flushPackets()
    }
}

func flushPackets() {
    let packets = packetBuffer.map { $0.0 }
    let protocols = packetBuffer.map { $0.1 }

    packetFlow.writePackets(packets, withProtocols: protocols)
    packetBuffer.removeAll()
}
```

### 2. 使用 DispatchQueue

```swift
private let processingQueue = DispatchQueue(
    label: "com.privatedeploy.vpn.processing",
    qos: .userInitiated
)

processingQueue.async {
    // 处理数据包
}
```

### 3. 内存池

```swift
class PacketPool {
    private var pool: [Data] = []
    private let maxSize = 100

    func acquire() -> Data {
        return pool.popLast() ?? Data(count: 2048)
    }

    func release(_ packet: Data) {
        guard pool.count < maxSize else { return }
        pool.append(packet)
    }
}
```

---

## ✅ 验证清单

完成集成后，请验证以下项目：

- [ ] Framework 已成功生成
- [ ] Framework 已添加到 Runner 和 VPNExtension
- [ ] Embed & Sign 设置正确
- [ ] Network Extension capability 已启用
- [ ] App Groups 已配置
- [ ] Entitlements 文件正确
- [ ] 应用可以正常编译
- [ ] VPN 可以成功启动
- [ ] 数据包正常转发
- [ ] 流量统计正确
- [ ] Console 日志正常
- [ ] 无内存警告
- [ ] 真机测试通过

---

## 📚 参考资料

- [gomobile 官方文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Network Extension 编程指南](https://developer.apple.com/documentation/networkextension)
- [Packet Tunnel Provider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)
- [App Groups](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups)
- [sing-box 文档](https://sing-box.sagernet.org/)

---

## 🆘 获取帮助

如遇到问题，请：

1. 查看 Console.app 日志
2. 检查 VPNCore.framework 是否正确编译
3. 参考 GOMOBILE_INTEGRATION.md
4. 提交 Issue 到项目仓库

---

*最后更新: 2024-11-05*
