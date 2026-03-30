import Flutter
import NetworkExtension
import UIKit

#if canImport(VPNCore)
import VPNCore
#endif

public class VpnPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let methodChannel = "com.privatedeploy.vpn/native"
    private static let eventChannel = "com.privatedeploy.vpn/events"
    private static let appGroupInfoKey = "PrivateDeployVPNAppGroup"
    private static let extensionBundleInfoKey = "PrivateDeployVPNExtensionBundleIdentifier"
    private static let defaultAppGroup = "group.com.privatedeploy.mobile"
    private static let configDefaultsKey = "vpn_config"
    private static let statusDefaultsKey = "vpn_status"
    private static let statsDefaultsKey = "vpn_stats"
    private static let unsupportedMessage =
        "iOS VPN core is not available in this build. Build and embed VPNCore.framework before using native VPN control."

    private var eventSink: FlutterEventSink?
    private var statusObserver: NSObjectProtocol?
    private var statusPollTimer: Timer?
    private var cachedManager: NETunnelProviderManager?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VpnPlugin()

        let methodChannel = FlutterMethodChannel(
            name: Self.methodChannel,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: Self.eventChannel,
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    deinit {
        stopStatusObservation()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startVpn":
            startVpn(call, result: result)
        case "stopVpn":
            stopVpn(result)
        case "restartVpn":
            restartVpn(result)
        case "getCapabilities":
            getCapabilities(result)
        case "isRunning":
            isRunning(result)
        case "getStatus":
            getStatus(result)
        case "getStats":
            getStats(result)
        case "getRecentLogs":
            result([])
        case "getEgressIp":
            result(nil)
        case "resetStats":
            resetStats(result)
        case "updateConfig":
            updateConfig(call, result: result)
        case "getVersion":
            getVersion(result)
        case "requestPermission":
            requestPermission(result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getCapabilities(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        result([
            "supported": true,
            "reason": NSNull(),
        ])
#else
        result([
            "supported": false,
            "reason": Self.unsupportedMessage,
        ])
#endif
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        startStatusObservation()
        publishStatusEvent()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopStatusObservation()
        return nil
    }

    private func startVpn(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
#if canImport(VPNCore)
        guard
            let arguments = call.arguments as? [String: Any],
            let config = arguments["config"] as? String,
            !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(flutterError(code: "INVALID_CONFIG", message: "VPN config is empty"))
            return
        }

        persistConfig(config)
        ensureManagerSaved { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_SAVE_FAILED", message: error.localizedDescription))
                return
            }
            guard let session = manager?.connection as? NETunnelProviderSession else {
                result(self.flutterError(code: "VPN_SESSION_UNAVAILABLE", message: "Tunnel provider session is unavailable"))
                return
            }
            do {
                try session.startVPNTunnel()
                self.publishStatusEvent()
                result(true)
            } catch {
                result(self.flutterError(code: "VPN_START_FAILED", message: error.localizedDescription))
            }
        }
#else
        result(flutterError(code: "UNSUPPORTED", message: Self.unsupportedMessage))
#endif
    }

    private func stopVpn(_ result: @escaping FlutterResult) {
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            manager?.connection.stopVPNTunnel()
            self.publishStatusEvent()
            result(true)
        }
    }

    private func restartVpn(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            guard let manager else {
                result(self.flutterError(code: "VPN_MANAGER_UNAVAILABLE", message: "Tunnel provider manager is unavailable"))
                return
            }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                self.sendProviderCommand(["action": "restart"], manager: manager) { commandError, _ in
                    if let commandError {
                        result(self.flutterError(code: "VPN_RESTART_FAILED", message: commandError.localizedDescription))
                        return
                    }
                    self.publishStatusEvent()
                    result(true)
                }
            default:
                if let session = manager.connection as? NETunnelProviderSession {
                    do {
                        try session.startVPNTunnel()
                        self.publishStatusEvent()
                        result(true)
                    } catch {
                        result(self.flutterError(code: "VPN_RESTART_FAILED", message: error.localizedDescription))
                    }
                } else {
                    result(self.flutterError(code: "VPN_SESSION_UNAVAILABLE", message: "Tunnel provider session is unavailable"))
                }
            }
        }
#else
        result(flutterError(code: "UNSUPPORTED", message: Self.unsupportedMessage))
#endif
    }

    private func isRunning(_ result: @escaping FlutterResult) {
        loadManager { manager, _ in
            result(self.isConnectedStatus(manager?.connection.status ?? .invalid))
        }
    }

    private func getStatus(_ result: @escaping FlutterResult) {
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            result(self.statusPayload(manager: manager))
        }
    }

    private func getStats(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            guard let manager, self.isConnectedStatus(manager.connection.status) else {
                result(self.statsPayload())
                return
            }
            self.sendProviderCommand(["action": "getStats"], manager: manager) { commandError, payload in
                if let commandError {
                    result(self.flutterError(code: "VPN_STATS_FAILED", message: commandError.localizedDescription))
                    return
                }
                if let payload {
                    result(payload)
                } else {
                    result(self.statsPayload())
                }
            }
        }
#else
        result([
            "upload_bytes": 0,
            "download_bytes": 0,
            "upload_speed": 0,
            "download_speed": 0,
            "memory_bytes": 0,
            "connections_in": 0,
            "connections_out": 0,
            "traffic_available": false,
        ])
#endif
    }

    private func resetStats(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            guard let manager, self.isConnectedStatus(manager.connection.status) else {
                self.persistStats([
                    "upload_bytes": 0,
                    "download_bytes": 0,
                    "upload_speed": 0,
                    "download_speed": 0,
                    "memory_bytes": 0,
                    "connections_in": 0,
                    "connections_out": 0,
                    "traffic_available": false,
                ])
                result(true)
                return
            }
            self.sendProviderCommand(["action": "resetStats"], manager: manager) { commandError, _ in
                if let commandError {
                    result(self.flutterError(code: "VPN_RESET_STATS_FAILED", message: commandError.localizedDescription))
                    return
                }
                result(true)
            }
        }
#else
        result(flutterError(code: "UNSUPPORTED", message: Self.unsupportedMessage))
#endif
    }

    private func updateConfig(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
#if canImport(VPNCore)
        guard
            let arguments = call.arguments as? [String: Any],
            let config = arguments["config"] as? String,
            !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(flutterError(code: "INVALID_CONFIG", message: "VPN config is empty"))
            return
        }

        persistConfig(config)
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            guard let manager, self.isConnectedStatus(manager.connection.status) else {
                result(true)
                return
            }
            self.sendProviderCommand(["action": "updateConfig", "config": config], manager: manager) { commandError, _ in
                if let commandError {
                    result(self.flutterError(code: "VPN_UPDATE_CONFIG_FAILED", message: commandError.localizedDescription))
                    return
                }
                result(true)
            }
        }
#else
        result(flutterError(code: "UNSUPPORTED", message: Self.unsupportedMessage))
#endif
    }

    private func getVersion(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        result(VPNCoreNewVPNService().getVersion())
#else
        result("PrivateDeploy VPN iOS")
#endif
    }

    private func requestPermission(_ result: @escaping FlutterResult) {
#if canImport(VPNCore)
        ensureManagerSaved { [weak self] _, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_PERMISSION_REQUEST_FAILED", message: error.localizedDescription))
                return
            }
            result(true)
        }
#else
        result(flutterError(code: "UNSUPPORTED", message: Self.unsupportedMessage))
#endif
    }

    private func loadManager(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error {
                completion(nil, error)
                return
            }

            let targetBundleId = self.extensionBundleIdentifier()
            let manager = managers?.first(where: {
                guard let proto = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == targetBundleId
            }) ?? managers?.first ?? NETunnelProviderManager()

            self.cachedManager = manager
            completion(manager, nil)
        }
    }

    private func ensureManagerSaved(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                completion(nil, error)
                return
            }
            guard let manager else {
                completion(nil, NSError(domain: "com.privatedeploy.mobile.vpn", code: 1001, userInfo: [
                    NSLocalizedDescriptionKey: "Tunnel provider manager is unavailable",
                ]))
                return
            }

            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.extensionBundleIdentifier()
            proto.serverAddress = "PrivateDeploy"
            proto.disconnectOnSleep = false
            proto.providerConfiguration = [
                Self.appGroupInfoKey: self.appGroupIdentifier(),
                "configKey": Self.configDefaultsKey,
                "statusKey": Self.statusDefaultsKey,
                "statsKey": Self.statsDefaultsKey,
            ]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "PrivateDeploy VPN"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError {
                    completion(nil, saveError)
                    return
                }
                manager.loadFromPreferences { loadError in
                    if let loadError {
                        completion(nil, loadError)
                        return
                    }
                    self.cachedManager = manager
                    completion(manager, nil)
                }
            }
        }
    }

    private func sendProviderCommand(
        _ payload: [String: Any],
        manager: NETunnelProviderManager,
        completion: @escaping (Error?, [String: Any]?) -> Void
    ) {
        guard let session = manager.connection as? NETunnelProviderSession else {
            completion(NSError(domain: "com.privatedeploy.mobile.vpn", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel provider session is unavailable",
            ]), nil)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try session.sendProviderMessage(data) { responseData in
                guard let responseData else {
                    completion(nil, nil)
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: responseData)
                    guard let dictionary = json as? [String: Any] else {
                        completion(nil, nil)
                        return
                    }
                    if let errorMessage = dictionary["error"] as? String, !errorMessage.isEmpty {
                        completion(NSError(domain: "com.privatedeploy.mobile.vpn", code: 1003, userInfo: [
                            NSLocalizedDescriptionKey: errorMessage,
                        ]), nil)
                        return
                    }
                    if let dataPayload = dictionary["data"] as? [String: Any] {
                        completion(nil, dataPayload)
                    } else {
                        completion(nil, dictionary)
                    }
                } catch {
                    completion(error, nil)
                }
            }
        } catch {
            completion(error, nil)
        }
    }

    private func persistConfig(_ config: String) {
        sharedDefaults()?.set(config, forKey: Self.configDefaultsKey)
    }

    private func persistStatus(_ status: [String: Any]) {
        sharedDefaults()?.set(status, forKey: Self.statusDefaultsKey)
    }

    private func persistStats(_ stats: [String: Any]) {
        sharedDefaults()?.set(stats, forKey: Self.statsDefaultsKey)
    }

    private func statusPayload(manager: NETunnelProviderManager?) -> [String: Any] {
        let status = manager?.connection.status ?? .invalid
        let sharedStatus = sharedDefaults()?.dictionary(forKey: Self.statusDefaultsKey) ?? [:]
        var payload: [String: Any] = [
            "running": isConnectedStatus(status),
            "status": statusString(status),
            "connected_at": sharedStatus["connected_at"] ?? 0,
            "uptime": sharedStatus["uptime"] ?? 0,
        ]
        payload["message"] = sharedStatus["message"] ?? NSNull()
        return payload
    }

    private func statsPayload() -> [String: Any] {
        (sharedDefaults()?.dictionary(forKey: Self.statsDefaultsKey) as? [String: Any]) ?? [
            "upload_bytes": 0,
            "download_bytes": 0,
            "upload_speed": 0,
            "download_speed": 0,
            "memory_bytes": 0,
            "connections_in": 0,
            "connections_out": 0,
            "traffic_available": false,
        ]
    }

    private func publishStatusEvent() {
        guard let eventSink else { return }
        loadManager { [weak self] manager, _ in
            guard let self else { return }
            eventSink([
                "type": "status",
                "data": self.statusPayload(manager: manager),
            ])
        }
    }

    private func startStatusObservation() {
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.publishStatusEvent()
            }
        }
        if statusPollTimer == nil {
            statusPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.publishStatusEvent()
            }
        }
    }

    private func stopStatusObservation() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func statusString(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected:
            return "connected"
        case .connecting, .reasserting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        case .disconnected, .invalid:
            return "disconnected"
        @unknown default:
            return "unknown"
        }
    }

    private func isConnectedStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private func appGroupIdentifier() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: Self.appGroupInfoKey) as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return Self.defaultAppGroup
    }

    private func extensionBundleIdentifier() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: Self.extensionBundleInfoKey) as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            return bundleId + ".VPNExtension"
        }
        return "com.privatedeploy.mobile.VPNExtension"
    }

    private func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier())
    }

    private func flutterError(code: String, message: String) -> FlutterError {
        FlutterError(code: code, message: message, details: nil)
    }
}
