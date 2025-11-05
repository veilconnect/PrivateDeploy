import Flutter
import UIKit
import NetworkExtension

/**
 * VPN Plugin for iOS
 *
 * 处理 Flutter 和 iOS Network Extension 之间的通信
 */
public class VpnPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private static let METHOD_CHANNEL = "com.privatedeploy.vpn/native"
    private static let EVENT_CHANNEL = "com.privatedeploy.vpn/events"

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var vpnManager: NETunnelProviderManager?
    private var isConnected = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VpnPlugin()

        let methodChannel = FlutterMethodChannel(
            name: METHOD_CHANNEL,
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: EVENT_CHANNEL,
            binaryMessenger: registrar.messenger()
        )
        instance.eventChannel = eventChannel
        eventChannel.setStreamHandler(instance)

        instance.setupVPNManager()
    }

    private func setupVPNManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                NSLog("[VpnPlugin] Error loading VPN preferences: \(error)")
                return
            }

            if let manager = managers?.first {
                self?.vpnManager = manager
            } else {
                self?.createVPNManager()
            }

            self?.observeVPNStatus()
        }
    }

    private func createVPNManager() {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "PrivateDeploy VPN"

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.privatedeploy.mobile.vpnextension"
        proto.serverAddress = "PrivateDeploy"

        manager.protocolConfiguration = proto
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            if let error = error {
                NSLog("[VpnPlugin] Error saving VPN preferences: \(error)")
            } else {
                self?.vpnManager = manager
                NSLog("[VpnPlugin] VPN manager created successfully")
            }
        }
    }

    private func observeVPNStatus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc private func vpnStatusDidChange() {
        guard let status = vpnManager?.connection.status else { return }

        let statusString: String
        let isConnected: Bool

        switch status {
        case .connected:
            statusString = "connected"
            isConnected = true
        case .connecting:
            statusString = "connecting"
            isConnected = false
        case .disconnected:
            statusString = "disconnected"
            isConnected = false
        case .disconnecting:
            statusString = "disconnecting"
            isConnected = false
        case .reasserting:
            statusString = "reconnecting"
            isConnected = false
        case .invalid:
            statusString = "invalid"
            isConnected = false
        @unknown default:
            statusString = "unknown"
            isConnected = false
        }

        self.isConnected = isConnected

        eventSink?([
            "type": "status",
            "data": [
                "running": isConnected,
                "status": statusString
            ]
        ])

        NSLog("[VpnPlugin] VPN status changed to: \(statusString)")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startVpn":
            startVpn(call: call, result: result)
        case "stopVpn":
            stopVpn(result: result)
        case "restartVpn":
            restartVpn(result: result)
        case "isRunning":
            isRunning(result: result)
        case "getStatus":
            getStatus(result: result)
        case "getStats":
            getStats(result: result)
        case "resetStats":
            resetStats(result: result)
        case "updateConfig":
            updateConfig(call: call, result: result)
        case "getVersion":
            getVersion(result: result)
        case "requestPermission":
            requestPermission(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startVpn(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let manager = vpnManager else {
            result(FlutterError(
                code: "NO_VPN_MANAGER",
                message: "VPN manager not initialized",
                details: nil
            ))
            return
        }

        guard let args = call.arguments as? [String: Any],
              let config = args["config"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Invalid arguments",
                details: nil
            ))
            return
        }

        // 保存配置到 UserDefaults (供 Network Extension 使用)
        if let sharedDefaults = UserDefaults(suiteName: "group.com.privatedeploy.mobile") {
            sharedDefaults.set(config, forKey: "vpn_config")
            sharedDefaults.synchronize()
        }

        do {
            try manager.connection.startVPNTunnel()
            result(true)
            NSLog("[VpnPlugin] VPN start requested")
        } catch {
            result(FlutterError(
                code: "START_FAILED",
                message: "Failed to start VPN: \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    private func stopVpn(result: @escaping FlutterResult) {
        guard let manager = vpnManager else {
            result(FlutterError(
                code: "NO_VPN_MANAGER",
                message: "VPN manager not initialized",
                details: nil
            ))
            return
        }

        manager.connection.stopVPNTunnel()
        result(true)
        NSLog("[VpnPlugin] VPN stop requested")
    }

    private func restartVpn(result: @escaping FlutterResult) {
        stopVpn { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                let call = FlutterMethodCall(methodName: "startVpn", arguments: ["config": ""])
                self?.startVpn(call: call, result: result)
            }
        }
    }

    private func isRunning(result: @escaping FlutterResult) {
        result(isConnected)
    }

    private func getStatus(result: @escaping FlutterResult) {
        result([
            "running": isConnected,
            "connected_at": 0,
            "uptime": 0
        ])
    }

    private func getStats(result: @escaping FlutterResult) {
        // TODO: 从 Network Extension 获取实际统计数据
        result([
            "upload_bytes": 0,
            "download_bytes": 0,
            "upload_speed": 0,
            "download_speed": 0
        ])
    }

    private func resetStats(result: @escaping FlutterResult) {
        // TODO: 重置 Network Extension 的统计数据
        result(true)
    }

    private func updateConfig(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let config = args["config"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Invalid arguments",
                details: nil
            ))
            return
        }

        if let sharedDefaults = UserDefaults(suiteName: "group.com.privatedeploy.mobile") {
            sharedDefaults.set(config, forKey: "vpn_config")
            sharedDefaults.synchronize()
        }

        result(true)
    }

    private func getVersion(result: @escaping FlutterResult) {
        result("PrivateDeploy VPN iOS 1.0.0")
    }

    private func requestPermission(result: @escaping FlutterResult) {
        // iOS VPN 权限在首次连接时自动请求
        result(true)
    }

    // FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        NSLog("[VpnPlugin] Event stream listener attached")
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        NSLog("[VpnPlugin] Event stream listener cancelled")
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
