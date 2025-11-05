import NetworkExtension
import os.log

/**
 * Packet Tunnel Provider for PrivateDeploy VPN
 *
 * 实现 iOS Network Extension 的核心类
 * 处理 VPN 数据包的路由和转发
 */
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var isRunning = false
    // TODO: 集成 Go Mobile VPN Core
    // private var vpnCore: VPNService?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("[PacketTunnelProvider] Starting tunnel...")

        // 从 UserDefaults 读取配置
        let config = loadConfig()
        os_log("[PacketTunnelProvider] Config loaded: %{public}@", config.isEmpty ? "empty" : "exists")

        // 配置网络设置
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")

        // IPv4 设置
        let ipv4Settings = NEIPv4Settings(
            addresses: ["10.0.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        // DNS 设置
        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.dnsSettings = dnsSettings

        // MTU
        settings.mtu = 1500

        // 应用网络设置
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log("[PacketTunnelProvider] Error setting network: %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }

            os_log("[PacketTunnelProvider] Network settings applied")

            // TODO: 启动 Go Mobile VPN Core
            // do {
            //     self?.vpnCore = VPNService()
            //     try self?.vpnCore?.start(config)
            //     self?.isRunning = true
            //     completionHandler(nil)
            // } catch {
            //     os_log("[PacketTunnelProvider] Error starting VPN core: %{public}@", error.localizedDescription)
            //     completionHandler(error)
            //     return
            // }

            self?.isRunning = true
            self?.startPacketProcessing()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("[PacketTunnelProvider] Stopping tunnel, reason: %{public}d", reason.rawValue)

        isRunning = false

        // TODO: 停止 Go Mobile VPN Core
        // vpnCore?.stop()
        // vpnCore = nil

        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // 处理来自主应用的消息
        os_log("[PacketTunnelProvider] Received app message")

        if let message = String(data: messageData, encoding: .utf8) {
            os_log("[PacketTunnelProvider] Message: %{public}@", message)
        }

        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // 处理设备睡眠
        os_log("[PacketTunnelProvider] Sleep")
        completionHandler()
    }

    override func wake() {
        // 处理设备唤醒
        os_log("[PacketTunnelProvider] Wake")
    }

    /**
     * 从 App Group UserDefaults 加载配置
     */
    private func loadConfig() -> String {
        if let sharedDefaults = UserDefaults(suiteName: "group.com.privatedeploy.mobile"),
           let config = sharedDefaults.string(forKey: "vpn_config") {
            return config
        }
        return ""
    }

    /**
     * 启动数据包处理
     */
    private func startPacketProcessing() {
        // 启动数据包读取
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            // TODO: 将数据包传递给 Go Mobile VPN Core 处理
            // for (index, packet) in packets.enumerated() {
            //     let proto = protocols[index]
            //     self.vpnCore?.handlePacket(packet, protocol: proto)
            // }

            // 继续读取
            self.startPacketProcessing()
        }
    }

    /**
     * 写入数据包到隧道
     */
    private func writePackets(_ packets: [Data], protocols: [NSNumber]) {
        guard isRunning else { return }
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}
