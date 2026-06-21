import Flutter
import CryptoKit
import NetworkExtension
import Security
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
    private static let secureConfigDefaultsKey = "vpn_config_secure_v1"
    private static let proxylessDefaultsKey = "vpn_proxyless"
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
        case "getInstalledApps":
            result([])
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

        let proxyless = (arguments["proxyless"] as? Bool) ?? false
        guard persistConfig(config) else {
            result(flutterError(code: "VPN_CONFIG_PERSIST_FAILED", message: "Failed to store VPN config securely"))
            return
        }
        persistProxyless(proxyless)
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

        let proxyless = arguments["proxyless"] as? Bool
        guard persistConfig(config) else {
            result(flutterError(code: "VPN_CONFIG_PERSIST_FAILED", message: "Failed to store VPN config securely"))
            return
        }
        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(self.flutterError(code: "VPN_MANAGER_LOAD_FAILED", message: error.localizedDescription))
                return
            }
            guard let manager, self.isConnectedStatus(manager.connection.status) else {
                if let proxyless {
                    self.persistProxyless(proxyless)
                }
                result(true)
                return
            }
            var command: [String: Any] = ["action": "updateConfig", "config": config]
            if let proxyless {
                command["proxyless"] = proxyless
            }
            self.sendProviderCommand(command, manager: manager) { commandError, _ in
                if let commandError {
                    result(self.flutterError(code: "VPN_UPDATE_CONFIG_FAILED", message: commandError.localizedDescription))
                    return
                }
                if let proxyless {
                    self.persistProxyless(proxyless)
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
                "configKey": Self.secureConfigDefaultsKey,
                "legacyConfigKey": Self.configDefaultsKey,
                "statusKey": Self.statusDefaultsKey,
                "statsKey": Self.statsDefaultsKey,
                "proxylessKey": Self.proxylessDefaultsKey,
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

    @discardableResult
    private func persistConfig(_ config: String) -> Bool {
        guard let sealed = sealConfig(config), let defaults = sharedDefaults() else {
            return false
        }
        defaults.set(sealed, forKey: Self.secureConfigDefaultsKey)
        defaults.removeObject(forKey: Self.configDefaultsKey)
        return true
    }

    private func persistProxyless(_ proxyless: Bool) {
        sharedDefaults()?.set(proxyless, forKey: Self.proxylessDefaultsKey)
    }

    private func loadProxyless() -> Bool {
        sharedDefaults()?.bool(forKey: Self.proxylessDefaultsKey) ?? false
    }

    private func sealConfig(_ config: String) -> String? {
        guard let key = VPNConfigKeyStore.loadOrCreateKey() else {
            return nil
        }
        do {
            let sealedBox = try AES.GCM.seal(Data(config.utf8), using: key)
            return sealedBox.combined?.base64EncodedString()
        } catch {
            return nil
        }
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
        let running = isConnectedStatus(status)
        var payload: [String: Any] = [
            "running": running,
            "status": statusString(status),
            "connected_at": sharedStatus["connected_at"] ?? 0,
            "uptime": sharedStatus["uptime"] ?? 0,
        ]
        payload["message"] = sharedStatus["message"] ?? NSNull()
        payload["proxyless"] = running && ((sharedStatus["proxyless"] as? Bool) ?? loadProxyless())
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

// VPNConfigKeyStore manages the per-install symmetric key used to seal the VPN
// config in the shared App Group. The key is random per install and lives in
// the keychain (the app and the Network Extension share it through their common
// `keychain-access-groups` entry, which is the default access group for both
// targets, so no explicit access group needs to be set here). This replaces the
// previous design where the sealing key was derived from a constant compiled
// into the binary — identical on every device and therefore reversible by
// anyone with the source.
fileprivate enum VPNConfigKeyStore {
    private static let service = "com.privatedeploy.mobile.vpn"
    private static let account = "vpn_config_sealing_key_v2"

    static func loadOrCreateKey() -> SymmetricKey? {
        if let existing = loadKey() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // The extension may run while the device is locked (background
            // reconnect), so AfterFirstUnlock is required; ThisDeviceOnly keeps
            // the key off iCloud Keychain / encrypted backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SymmetricKey(data: data)
        }
        if status == errSecDuplicateItem {
            // Another target created it concurrently; read the winning value.
            return loadKey()
        }
        return nil
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }
}
