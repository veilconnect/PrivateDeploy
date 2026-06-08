# iOS Go Mobile Integration Guide

**English** | [中文](IOS_INTEGRATION.zh-CN.md)

This document explains in detail how to integrate the Framework compiled by Go Mobile into the PrivateDeploy iOS app.

---

## 📋 Prerequisites

### Development Environment

- **macOS**: Monterey (12.0) or later
- **Xcode**: 14.0 or later
- **iOS SDK**: iOS 12.0+
- **Go**: 1.21 or later
- **gomobile**: latest version
- **CocoaPods**: 1.11.0 or later (optional)

### Apple Developer Account

- A valid Apple Developer account
- A configured development certificate
- Network Extension Capability enabled

---

## 🔧 Step 1: Compile the Go Mobile Library

### 1.1 Install gomobile

```bash
# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# Initialize gomobile (requires Xcode)
gomobile init
```

### 1.2 Compile the Framework

```bash
# Enter the gomobile directory
cd ~/PrivateDeploy/mobile/gomobile

# Run the build script
./build-ios.sh
```

After a successful build, the Framework will be generated at:
```
~/PrivateDeploy/mobile/ios/VPNCore.framework
```

### 1.3 Verify the Framework

```bash
# View the supported architectures
lipo -info ios/VPNCore.framework/VPNCore

# The output should include:
# arm64 (physical device)
# x86_64 (simulator, if included during compilation)

# View the exported symbols
nm -g ios/VPNCore.framework/VPNCore | head -20
```

---

## 🔗 Step 2: Integrate into the Xcode Project

### 2.1 Open the Xcode Project

```bash
# Open the workspace (recommended)
open ios/Runner.xcworkspace

# Or open the project
open ios/Runner.xcodeproj
```

### 2.2 Add the Framework

1. In Xcode, select the **Runner** project
2. Select the **Runner** target
3. Switch to the **General** tab
4. Scroll to **Frameworks, Libraries, and Embedded Content**
5. Click the **+** button
6. Choose **Add Other...** → **Add Files...**
7. Navigate to `ios/VPNCore.framework`
8. Select it and click **Open**
9. Make sure it is set to **Embed & Sign**

### 2.3 Configure Build Settings

In **Build Settings**:

```
Framework Search Paths: $(PROJECT_DIR)
```

### 2.4 Add the Framework for the Network Extension

Repeat the steps above to add the Framework to the **VPNExtension** target:

1. Select the **VPNExtension** target
2. Add `VPNCore.framework`
3. Set it to **Embed & Sign**

---

## 💻 Step 3: Use the Go Library in Code

### 3.1 Import the Go Package

In `PacketTunnelProvider.swift`:

```swift
import NetworkExtension
import VPNCore

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var vpnCore: VPNCoreVPNService?

    override func startTunnel(options: [String : NSObject]?,
                            completionHandler: @escaping (Error?) -> Void) {
        os_log("[PacketTunnelProvider] Starting tunnel...")

        // Load configuration
        let config = loadConfig()

        // Create the VPN Core instance
        do {
            vpnCore = VPNCoreNewVPNService()

            // Start the VPN
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

### 3.2 Handle Packets

```swift
private func startPacketProcessing() {
    packetFlow.readPackets { [weak self] packets, protocols in
        guard let self = self,
              let vpnCore = self.vpnCore else { return }

        do {
            // Process each packet
            for (index, packet) in packets.enumerated() {
                let protocolNumber = protocols[index].intValue

                // Pass it to the Go Mobile VPN Core
                try vpnCore.handlePacket(packet, protocolNumber)
            }

            // Continue reading
            self.startPacketProcessing()

        } catch {
            os_log("[PacketTunnelProvider] Error handling packet: %{public}@",
                   error.localizedDescription)
        }
    }
}

// Write packets
private func writePackets(_ packets: [Data], protocols: [NSNumber]) {
    guard let vpnCore = vpnCore else { return }

    do {
        // Batch write
        packetFlow.writePackets(packets, withProtocols: protocols)

    } catch {
        os_log("[PacketTunnelProvider] Error writing packets: %{public}@",
               error.localizedDescription)
    }
}
```

### 3.3 Retrieve Traffic Statistics

```swift
private func getStats() -> VPNCoreTrafficStats? {
    guard let vpnCore = vpnCore else { return nil }

    do {
        // Get the statistics in JSON format
        let statsJSON = try vpnCore.getStats()

        // Parse the JSON
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

## 🔐 Step 4: Configure Capabilities

### 4.1 Enable Network Extension

1. Select the **Runner** target
2. Switch to the **Signing & Capabilities** tab
3. Click **+ Capability**
4. Search for and add **Network Extensions**
5. Check **Packet Tunnel**

### 4.2 Configure App Groups

1. In **Capabilities**, click **+ Capability**
2. Add **App Groups**
3. Click **+** to add a new App Group
4. Enter: `group.com.privatedeploy.mobile`
5. Repeat the steps above for the **VPNExtension** target

### 4.3 Configure Keychain Sharing

1. Add the **Keychain Sharing** capability
2. Add the keychain group: `$(AppIdentifierPrefix)com.privatedeploy.mobile`

---

## 🐛 Step 5: Debugging and Testing

### 5.1 Enable Logging

In the Network Extension:

```swift
import os.log

let logger = OSLog(subsystem: "com.privatedeploy.mobile.vpnextension",
                   category: "VPN")

os_log("VPN started", log: logger, type: .info)
```

### 5.2 View Logs

Use Console.app or the command line:

```bash
# View logs in real time
log stream --predicate 'process == "VPNExtension"'

# View a specific subsystem
log stream --predicate 'subsystem == "com.privatedeploy.mobile.vpnextension"'
```

### 5.3 Debug the Network Extension

**Note**: The Network Extension cannot be debugged directly in Xcode

Debugging methods:
1. Use `os_log` to output detailed logs
2. Save error information to the App Group's shared container
3. Read and display it in the main app

```swift
// Write logs to the shared container
let fileManager = FileManager.default
if let containerURL = fileManager.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.privatedeploy.mobile") {

    let logFile = containerURL.appendingPathComponent("vpn.log")
    try? "VPN started".write(to: logFile, atomically: true, encoding: .utf8)
}
```

### 5.4 Test the VPN Connection

```swift
// Test in the main app
let vpnPlugin = VpnPlugin()

// Start the VPN
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

## ⚠️ Common Issues

### Issue 1: Framework Not Found

**Symptom**: The build fails with `ld: framework not found VPNCore`

**Solution**:
```bash
# Check whether the Framework exists
ls -la ios/VPNCore.framework

# Recompile
cd gomobile
./build-ios.sh

# Check the Framework Search Paths in Xcode
# Build Settings → Framework Search Paths → $(PROJECT_DIR)
```

### Issue 2: Symbol Not Found

**Symptom**: Runtime error `dyld: Symbol not found: _VPNCoreNewVPNService`

**Solution**:
```swift
// Check the import
import VPNCore

// Make sure the Framework is set to Embed & Sign
// rather than Do Not Embed
```

### Issue 3: Network Extension Permission Error

**Symptom**: `NEVPNError: Configuration is invalid`

**Solution**:
```swift
// Make sure the following are enabled in Capabilities:
// - Network Extensions (Packet Tunnel)
// - App Groups

// Check the Entitlements files
// Runner.entitlements and VPNExtension.entitlements
```

### Issue 4: Go Panic Crash

**Symptom**: The Extension crashes and the Console shows a Go panic

**Solution**:
```swift
// Add error handling
do {
    try vpnCore?.start(config)
} catch {
    os_log("Go error: %{public}@", error.localizedDescription)
    completionHandler(error)
    return
}
```

### Issue 5: Memory Limit

**Symptom**: The Extension is terminated by the system due to memory pressure

**Solution**:
```swift
// The Network Extension has a ~30MB memory limit
// Optimize memory usage:

// 1. Use autoreleasepool
autoreleasepool {
    // Process packets
}

// 2. Release large objects promptly
var largeData: Data? = someData
// After use
largeData = nil

// 3. Monitor memory
let memoryUsage = reportMemory()
os_log("Memory usage: %{public}d MB", memoryUsage)
```

---

## 🔒 Security Considerations

### App Transport Security

Configure in `Info.plist` (if needed):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
</dict>
```

### Keychain Access

```swift
// Use the Keychain to store sensitive configuration
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: "vpn_config",
    kSecAttrAccessGroup as String: "$(AppIdentifierPrefix)com.privatedeploy.mobile",
    kSecValueData as String: configData
]

SecItemAdd(query as CFDictionary, nil)
```

### Data Encryption

```swift
// Use CryptoKit to encrypt sensitive data
import CryptoKit

let key = SymmetricKey(size: .bits256)
let encrypted = try AES.GCM.seal(data, using: key)
```

---

## 📊 Performance Optimization

### 1. Batch Process Packets

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

### 2. Use DispatchQueue

```swift
private let processingQueue = DispatchQueue(
    label: "com.privatedeploy.vpn.processing",
    qos: .userInitiated
)

processingQueue.async {
    // Process packets
}
```

### 3. Memory Pool

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

## ✅ Verification Checklist

After completing the integration, please verify the following items:

- [ ] The Framework has been successfully generated
- [ ] The Framework has been added to Runner and VPNExtension
- [ ] Embed & Sign is set correctly
- [ ] The Network Extension capability is enabled
- [ ] App Groups are configured
- [ ] The Entitlements files are correct
- [ ] The app compiles normally
- [ ] The VPN can start successfully
- [ ] Packets are forwarded normally
- [ ] Traffic statistics are correct
- [ ] Console logs are normal
- [ ] No memory warnings
- [ ] Physical device testing passes

---

## 📚 References

- [gomobile Official Documentation](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Network Extension Programming Guide](https://developer.apple.com/documentation/networkextension)
- [Packet Tunnel Provider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)
- [App Groups](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups)
- [sing-box Documentation](https://sing-box.sagernet.org/)

---

## 🆘 Getting Help

If you run into problems, please:

1. Check the Console.app logs
2. Check whether VPNCore.framework is compiled correctly
3. Refer to GOMOBILE_INTEGRATION.md
4. Submit an Issue to the project repository

---

*Last updated: 2024-11-05*
