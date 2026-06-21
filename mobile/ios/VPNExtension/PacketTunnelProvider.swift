import Foundation
import CryptoKit
import NetworkExtension
import Security
import os.log

#if canImport(VPNCore)
import VPNCore
#endif

class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum SharedKeys {
        static let appGroup = "group.com.privatedeploy.mobile"
        static let appGroupConfigKey = "PrivateDeployVPNAppGroup"
        static let configDefaultsKey = "vpn_config"
        static let secureConfigDefaultsKey = "vpn_config_secure_v1"
        static let proxylessDefaultsKey = "vpn_proxyless"
        static let statusDefaultsKey = "vpn_status"
        static let statsDefaultsKey = "vpn_stats"
        // Legacy sealing key material. Retained ONLY to decrypt configs sealed
        // by builds that predate the per-install keychain key, so they can be
        // re-sealed under the new key on first read. Never used to seal.
        static let legacyConfigEncryptionKeyMaterial =
            "PrivateDeploy iOS VPN config sealing v1"
    }

    private enum TunnelError {
        static let domain = "com.privatedeploy.mobile.vpn"
        static let unsupportedCode = 1001
        static let unsupportedMessage =
            "iOS VPN core is not available in this build. Build and embed VPNCore.framework before enabling PacketTunnelProvider."
        static let emptyConfigMessage =
            "VPN config is empty. Activate a profile with a valid sing-box config before connecting."
    }

    private let logger = OSLog(subsystem: "com.privatedeploy.mobile.vpnextension", category: "VPN")
    private var proxylessTunnel = false

#if canImport(VPNCore)
    private var vpnCore: VPNCoreVPNService?
    private var statusTimer: DispatchSourceTimer?
#endif

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("[PacketTunnelProvider] Starting tunnel...", log: logger, type: .info)

        proxylessTunnel = loadProxyless()
        let config = loadConfig()
        if config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let error = NSError(
                domain: TunnelError.domain,
                code: TunnelError.unsupportedCode,
                userInfo: [NSLocalizedDescriptionKey: TunnelError.emptyConfigMessage]
            )
            persistStatus(errorStatusPayload(message: TunnelError.emptyConfigMessage))
            completionHandler(error)
            return
        }

#if canImport(VPNCore)
        do {
            let core = try ensureVpnCore()
            try core.start(config)
            persistRuntimeState()
            startStatusTimer()
            completionHandler(nil)
        } catch {
            os_log("[PacketTunnelProvider] Failed to start VPN core: %{public}@", log: logger, type: .error, error.localizedDescription)
            stopStatusTimer()
            persistStatus(errorStatusPayload(message: error.localizedDescription))
            completionHandler(error)
        }
#else
        let error = NSError(
            domain: TunnelError.domain,
            code: TunnelError.unsupportedCode,
            userInfo: [NSLocalizedDescriptionKey: TunnelError.unsupportedMessage]
        )
        persistStatus(errorStatusPayload(message: TunnelError.unsupportedMessage))
        completionHandler(error)
#endif
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("[PacketTunnelProvider] Stopping tunnel, reason: %{public}d", log: logger, type: .info, reason.rawValue)
#if canImport(VPNCore)
        stopStatusTimer()
        do {
            try vpnCore?.stop()
        } catch {
            os_log("[PacketTunnelProvider] Failed to stop VPN core: %{public}@", log: logger, type: .error, error.localizedDescription)
        }
        vpnCore = nil
        proxylessTunnel = false
        persistStatus(disconnectedStatusPayload())
        persistStats(defaultStatsPayload())
#else
        persistStatus(disconnectedStatusPayload())
#endif
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
#if canImport(VPNCore)
        let response: [String: Any]
        do {
            let message = try decodeMessage(messageData)
            response = try handleMessage(message)
        } catch {
            response = ["error": error.localizedDescription]
        }
        completionHandler(encodeMessage(response))
#else
        completionHandler(encodeMessage(["error": TunnelError.unsupportedMessage]))
#endif
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
#if canImport(VPNCore)
        persistRuntimeState()
#endif
    }

    private func appGroupIdentifier() -> String {
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfig = proto.providerConfiguration,
           let configured = providerConfig[SharedKeys.appGroupConfigKey] as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return SharedKeys.appGroup
    }

    private func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier())
    }

    private func loadConfig() -> String {
        guard let defaults = sharedDefaults() else {
            return ""
        }
        if let sealed = defaults.string(forKey: SharedKeys.secureConfigDefaultsKey),
           let opened = openConfig(sealed) {
            return opened
        }

        let legacy = defaults.string(forKey: SharedKeys.configDefaultsKey) ?? ""
        if !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           persistConfig(legacy) {
            defaults.removeObject(forKey: SharedKeys.configDefaultsKey)
        }
        return legacy
    }

    @discardableResult
    private func persistConfig(_ config: String) -> Bool {
        guard let sealed = sealConfig(config), let defaults = sharedDefaults() else {
            return false
        }
        defaults.set(sealed, forKey: SharedKeys.secureConfigDefaultsKey)
        defaults.removeObject(forKey: SharedKeys.configDefaultsKey)
        return true
    }

    private func loadProxyless() -> Bool {
        sharedDefaults()?.bool(forKey: SharedKeys.proxylessDefaultsKey) ?? false
    }

    private func persistProxyless(_ proxyless: Bool) {
        sharedDefaults()?.set(proxyless, forKey: SharedKeys.proxylessDefaultsKey)
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

    private func openConfig(_ sealedConfig: String) -> String? {
        guard let data = Data(base64Encoded: sealedConfig) else {
            return nil
        }

        // Preferred path: the per-install keychain key.
        if let key = VPNConfigKeyStore.loadOrCreateKey(),
           let plain = openSealed(data, key: key) {
            return plain
        }

        // Migration path: a build prior to the per-install key sealed this
        // config with a key derived from a compiled-in constant. Decrypt it
        // once, then immediately re-seal under the per-install key so the
        // legacy key is never needed again.
        if let plain = openSealed(data, key: legacySealingKey()) {
            _ = persistConfig(plain)
            os_log("[PacketTunnelProvider] Migrated VPN config to per-install sealing key", log: logger, type: .info)
            return plain
        }

        return nil
    }

    private func openSealed(_ data: Data, key: SymmetricKey) -> String? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let opened = try AES.GCM.open(sealedBox, using: key)
            return String(data: opened, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func legacySealingKey() -> SymmetricKey {
        let digest = SHA256.hash(
            data: Data(SharedKeys.legacyConfigEncryptionKeyMaterial.utf8)
        )
        return SymmetricKey(data: Data(digest))
    }

    private func persistStatus(_ status: [String: Any]) {
        sharedDefaults()?.set(status, forKey: SharedKeys.statusDefaultsKey)
    }

    private func persistStats(_ stats: [String: Any]) {
        sharedDefaults()?.set(stats, forKey: SharedKeys.statsDefaultsKey)
    }

    private func disconnectedStatusPayload() -> [String: Any] {
        [
            "running": false,
            "status": "disconnected",
            "message": NSNull(),
            "connected_at": 0,
            "uptime": 0,
            "proxyless": false,
        ]
    }

    private func errorStatusPayload(message: String) -> [String: Any] {
        [
            "running": false,
            "status": "error",
            "message": message,
            "connected_at": 0,
            "uptime": 0,
            "proxyless": false,
        ]
    }

    private func defaultStatsPayload() -> [String: Any] {
        [
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

    private func decodeMessage(_ data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = json as? [String: Any] else {
            throw NSError(domain: TunnelError.domain, code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "Invalid provider message payload",
            ])
        }
        return dictionary
    }

    private func encodeMessage(_ payload: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: payload)
    }

#if canImport(VPNCore)
    private func ensureVpnCore() throws -> VPNCoreVPNService {
        if let vpnCore {
            return vpnCore
        }

        let appGroupUrl = try appGroupContainerURL()
        let runtimeRoot = appGroupUrl.appendingPathComponent("vpncore", isDirectory: true)
        let workingPath = runtimeRoot.appendingPathComponent("working", isDirectory: true)
        let tempPath = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: workingPath, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: tempPath, withIntermediateDirectories: true, attributes: nil)

        let created = VPNCoreNewVPNService()
        created.setPlatform(self)
        created.configureRuntime(runtimeRoot.path, workingPath: workingPath.path, tempPath: tempPath.path)
        created.setUnderNetworkExtension(true)
        created.setIncludeAllNetworks(true)
        created.setUsePlatformAutoDetectInterfaceControl(false)
        vpnCore = created
        return created
    }

    private func appGroupContainerURL() throws -> URL {
        guard let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier()) else {
            throw NSError(domain: TunnelError.domain, code: 1004, userInfo: [
                NSLocalizedDescriptionKey: "App Group container is unavailable",
            ])
        }
        return containerUrl
    }

    private func startStatusTimer() {
        stopStatusTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.privatedeploy.mobile.vpnextension.status"))
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.persistRuntimeState()
        }
        statusTimer = timer
        timer.resume()
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    private func persistRuntimeState() {
        persistStatus(readStatusPayload())
        persistStats(readStatsPayload())
    }

    private func readStatusPayload() -> [String: Any] {
        guard let statusJson = vpnCore?.getStatus(),
              var payload = decodeJsonString(statusJson) else {
            return disconnectedStatusPayload()
        }
        let status = (payload["status"] as? String)?.lowercased() ?? ""
        let running = (payload["running"] as? Bool) ??
            (status == "connected" || status == "connecting" || status == "reasserting")
        payload["proxyless"] = running && proxylessTunnel
        return payload
    }

    private func readStatsPayload() -> [String: Any] {
        guard let statsJson = vpnCore?.getStats(),
              let payload = decodeJsonString(statsJson) else {
            return defaultStatsPayload()
        }
        return payload
    }

    private func decodeJsonString(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func handleMessage(_ message: [String: Any]) throws -> [String: Any] {
        let action = (message["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case "getStatus":
            let status = readStatusPayload()
            persistStatus(status)
            return ["data": status]
        case "getStats":
            let stats = readStatsPayload()
            persistStats(stats)
            return ["data": stats]
        case "resetStats":
            vpnCore?.resetStats()
            let stats = readStatsPayload()
            persistStats(stats)
            return ["ok": true, "data": stats]
        case "updateConfig":
            let config = (message["config"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !config.isEmpty else {
                throw NSError(domain: TunnelError.domain, code: 1005, userInfo: [
                    NSLocalizedDescriptionKey: "VPN config is empty",
                ])
            }
            guard persistConfig(config) else {
                throw NSError(domain: TunnelError.domain, code: 1009, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to store VPN config securely",
                ])
            }
            let requestedProxyless = message["proxyless"] as? Bool
            try vpnCore?.updateConfig(config)
            if let requestedProxyless {
                proxylessTunnel = requestedProxyless
                persistProxyless(requestedProxyless)
            }
            persistRuntimeState()
            return ["ok": true]
        case "restart":
            try vpnCore?.restart()
            persistRuntimeState()
            return ["ok": true, "data": readStatusPayload()]
        default:
            throw NSError(domain: TunnelError.domain, code: 1006, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported provider action: \(action)",
            ])
        }
    }
#endif
}

#if canImport(VPNCore)
extension PacketTunnelProvider: VPNCorePlatform {
    func openTun(_ options: VPNCoreTunConfig?) throws -> Int32 {
        guard let options else {
            throw NSError(domain: TunnelError.domain, code: 1007, userInfo: [
                NSLocalizedDescriptionKey: "TUN options are missing",
            ])
        }

        let settings = buildNetworkSettings(from: options)
        let semaphore = DispatchSemaphore(value: 0)
        var applyError: Error?
        var fileDescriptor: Int32 = -1

        setTunnelNetworkSettings(settings) { error in
            applyError = error
            if error == nil {
                fileDescriptor = VPNCoreGetTunnelFileDescriptor()
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + .seconds(15))

        if let applyError {
            throw applyError
        }
        if fileDescriptor < 0 {
            throw NSError(domain: TunnelError.domain, code: 1008, userInfo: [
                NSLocalizedDescriptionKey: "Failed to obtain tunnel file descriptor from VPNCore",
            ])
        }
        return fileDescriptor
    }

    func autoDetectInterfaceControl(_ fd: Int32) throws {
        _ = fd
    }

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else {
            return
        }
        os_log("[vpncore] %{public}@", log: logger, type: .debug, message)
    }

    func getNetworkInterfaces() -> String {
        "[]"
    }

    private func buildNetworkSettings(from options: VPNCoreTunConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let ipv4Prefixes = parsePrefixes(options.getInet4AddressList())
        if !ipv4Prefixes.isEmpty {
            let addresses = ipv4Prefixes.map(\.address)
            let masks = ipv4Prefixes.map(\.subnetMask)
            let ipv4 = NEIPv4Settings(addresses: addresses, subnetMasks: masks)
            let includedRoutes = parseRoutes(options.getRouteAddressList(), ipv6: false).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.subnetMask)
            }
            ipv4.includedRoutes = includedRoutes.isEmpty ? [NEIPv4Route.default()] : includedRoutes
            ipv4.excludedRoutes = parseRoutes(options.getRouteExcludeAddressList(), ipv6: false).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.subnetMask)
            }
            settings.ipv4Settings = ipv4
        }

        let ipv6Prefixes = parsePrefixes(options.getInet6AddressList())
        if !ipv6Prefixes.isEmpty {
            let ipv6 = NEIPv6Settings(
                addresses: ipv6Prefixes.map(\.address),
                networkPrefixLengths: ipv6Prefixes.map { NSNumber(value: $0.prefixLength) }
            )
            let includedRoutes = parseRoutes(options.getRouteAddressList(), ipv6: true).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            ipv6.includedRoutes = includedRoutes.isEmpty ? [NEIPv6Route.default()] : includedRoutes
            ipv6.excludedRoutes = parseRoutes(options.getRouteExcludeAddressList(), ipv6: true).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            settings.ipv6Settings = ipv6
        }

        let dnsServers = parseLines(options.getDNSServerAddress())
        if !dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        }

        if options.isHTTPProxyEnabled() {
            let host = options.getHTTPProxyServer().trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(options.getHTTPProxyServerPort())
            if !host.isEmpty, port > 0 {
                let proxy = NEProxySettings()
                proxy.httpEnabled = true
                proxy.httpServer = NEProxyServer(address: host, port: port)
                proxy.httpsEnabled = true
                proxy.httpsServer = NEProxyServer(address: host, port: port)
                settings.proxySettings = proxy
            }
        }

        return settings
    }

    private func parseRoutes(_ raw: String, ipv6: Bool) -> [(address: String, subnetMask: String, prefixLength: Int)] {
        parsePrefixes(raw).filter { prefix in
            prefix.address.contains(":") == ipv6
        }
    }

    private func parsePrefixes(_ raw: String) -> [(address: String, subnetMask: String, prefixLength: Int)] {
        parseLines(raw).compactMap { line in
            let parts = line.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let prefixLength = Int(parts[1]) else {
                return nil
            }
            return (
                address: parts[0],
                subnetMask: subnetMask(for: prefixLength, ipv6: parts[0].contains(":")),
                prefixLength: prefixLength
            )
        }
    }

    private func parseLines(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func subnetMask(for prefixLength: Int, ipv6: Bool) -> String {
        if ipv6 {
            return String(prefixLength)
        }
        var value: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - UInt32(prefixLength))
        let octets = (0..<4).map { _ -> String in
            let octet = (value & 0xff00_0000) >> 24
            value <<= 8
            return String(octet)
        }
        return octets.joined(separator: ".")
    }
}
#endif

// VPNConfigKeyStore manages the per-install symmetric key used to seal the VPN
// config in the shared App Group. The key is random per install and lives in
// the keychain, shared with the main app through the common
// `keychain-access-groups` entitlement (the default access group for both
// targets). This mirrors the helper in the main app's VpnPlugin.swift; the two
// targets are separate modules so the type is intentionally duplicated.
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SymmetricKey(data: data)
        }
        if status == errSecDuplicateItem {
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
