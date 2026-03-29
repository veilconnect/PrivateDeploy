package com.privatedeploy.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.privatedeploy.mobile.vpncore.gomobile.Gomobile
import com.privatedeploy.mobile.vpncore.gomobile.Platform
import com.privatedeploy.mobile.vpncore.gomobile.TunConfig
import com.privatedeploy.mobile.vpncore.gomobile.VPNService
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.NetworkInterface
import java.net.InetAddress
import java.util.ArrayDeque
import kotlin.concurrent.thread

/**
 * PrivateDeploy VPN Service
 *
 * 通过 Android VpnService 创建 TUN，并把底层 FD 交给 libbox 驱动的
 * Go VPN runtime。这样移动端使用的就是真正的 sing-box 移动运行时，
 * 而不是此前的 packet loop 占位实现。
 */
class PrivateDeployVpnService : VpnService(), Platform {

    companion object {
        private const val TAG = "PrivateDeployVPN"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "PrivateDeployVPN"
        private const val VPN_REVOKED_MESSAGE =
            "VPN permission was revoked or another VPN app/system VPN interrupted this connection. Disable the other VPN and try again."
        private const val INTERFACE_FLAG_UP = 1
        private const val INTERFACE_FLAG_MULTICAST = 1 shl 5
        private const val INTERFACE_FLAG_RUNNING = 1 shl 6
        private const val INTERFACE_TYPE_WIFI = 0
        private const val INTERFACE_TYPE_CELLULAR = 1
        private const val INTERFACE_TYPE_ETHERNET = 2
        private const val INTERFACE_TYPE_OTHER = 3
        private const val MAX_RECENT_LOGS = 250
        private val recentRuntimeLogs = ArrayDeque<RuntimeLogRecord>()

        @Volatile
        var isRunning = false
            private set

        @Volatile
        private var serviceInstance: PrivateDeployVpnService? = null

        internal fun runtimeSupportError(): String? = null

        internal fun currentStatus(): Map<String, Any?> {
            return serviceInstance?.statusMap() ?: mapOf(
                "running" to false,
                "status" to "disconnected",
                "message" to null,
                "connected_at" to 0,
                "uptime" to 0
            )
        }

        internal fun currentStats(): Map<String, Any?> {
            return serviceInstance?.statsMap() ?: mapOf(
                "upload_bytes" to 0,
                "download_bytes" to 0,
                "upload_speed" to 0,
                "download_speed" to 0,
                "memory_bytes" to 0,
                "connections_in" to 0,
                "connections_out" to 0,
                "traffic_available" to false
            )
        }

        internal fun currentRecentLogs(): List<Map<String, Any?>> {
            synchronized(recentRuntimeLogs) {
                return recentRuntimeLogs.map { record ->
                    mapOf(
                        "message" to record.message,
                        "timestamp" to record.timestamp,
                    )
                }
            }
        }

        private fun clearRecentLogs() {
            synchronized(recentRuntimeLogs) {
                recentRuntimeLogs.clear()
            }
        }

        private fun appendRecentLog(message: String, timestamp: Long) {
            synchronized(recentRuntimeLogs) {
                if (recentRuntimeLogs.size >= MAX_RECENT_LOGS) {
                    recentRuntimeLogs.removeFirst()
                }
                recentRuntimeLogs.addLast(RuntimeLogRecord(timestamp, message))
            }
        }

        internal fun currentVersion(): String {
            return try {
                Gomobile.newVPNService().getVersion()
            } catch (e: Exception) {
                "PrivateDeploy VPN Android"
            }
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var vpnCore: VPNService? = null
    private var activeConfig: String? = null

    override fun onCreate() {
        super.onCreate()
        serviceInstance = this
        createNotificationChannel()
        Log.d(TAG, "VPN Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startVpn(intent.getStringExtra(EXTRA_CONFIG).orEmpty())
            ACTION_STOP -> stopVpn()
            ACTION_RESTART -> restartVpn()
            ACTION_UPDATE_CONFIG -> updateConfig(intent.getStringExtra(EXTRA_CONFIG).orEmpty())
            ACTION_RESET_STATS -> resetStats()
        }
        return START_NOT_STICKY
    }

    private fun startVpn(config: String) {
        if (isRunning) {
            Log.w(TAG, "VPN is already running")
            return
        }
        if (config.isBlank()) {
            broadcastError("VPN config is empty")
            return
        }

        // Pre-validate config JSON structure before passing to Go runtime
        try {
            val json = JSONObject(config)
            if (!json.has("outbounds")) {
                broadcastError("Invalid config: missing \"outbounds\" section")
                return
            }
            val outbounds = json.optJSONArray("outbounds")
            if (outbounds == null || outbounds.length() == 0) {
                broadcastError("Invalid config: \"outbounds\" is empty")
                return
            }
        } catch (e: Exception) {
            broadcastError("Invalid config: not valid JSON - ${e.message}")
            return
        }

        activeConfig = config
        clearRecentLogs()
        startForeground(NOTIFICATION_ID, createNotification("VPN is connecting"))
        broadcastStatus("connecting", null)

        thread(name = "PrivateDeploy-VPN-Start") {
            try {
                val core = ensureVpnCore()
                core.start(config)
                isRunning = true
                broadcastStatus("connected", null)
                Log.i(TAG, "VPN started successfully")
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to start VPN", e)
                cleanupTunnel()
                stopForeground(STOP_FOREGROUND_REMOVE)
                isRunning = false
                broadcastError(e.message ?: "Failed to start VPN")
                stopSelf()
            }
        }
    }

    private fun stopVpn() {
        broadcastStatus("disconnecting", null)
        thread(name = "PrivateDeploy-VPN-Stop") {
            try {
                vpnCore?.stop()
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping VPN runtime", e)
            } finally {
                cleanupTunnel()
                isRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                broadcastStatus("disconnected", null)
                stopSelf()
                Log.i(TAG, "VPN stopped")
            }
        }
    }

    private fun restartVpn() {
        val config = activeConfig
        if (config.isNullOrBlank()) {
            broadcastError("No VPN config available for restart")
            return
        }

        thread(name = "PrivateDeploy-VPN-Restart") {
            try {
                startForeground(NOTIFICATION_ID, createNotification("VPN is reconnecting"))
                broadcastStatus("connecting", null)
                val core = ensureVpnCore()
                core.restart()
                isRunning = true
                broadcastStatus("connected", null)
                Log.i(TAG, "VPN restarted successfully")
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to restart VPN", e)
                cleanupTunnel()
                stopForeground(STOP_FOREGROUND_REMOVE)
                isRunning = false
                broadcastError(e.message ?: "Failed to restart VPN")
                stopSelf()
            }
        }
    }

    private fun updateConfig(config: String) {
        if (config.isBlank()) {
            broadcastError("VPN config is empty")
            return
        }

        thread(name = "PrivateDeploy-VPN-UpdateConfig") {
            try {
                val core = ensureVpnCore()
                core.updateConfig(config)
                activeConfig = config
                Log.i(TAG, "VPN config updated")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update VPN config", e)
                broadcastError(e.message ?: "Failed to update VPN config")
            }
        }
    }

    private fun resetStats() {
        try {
            vpnCore?.resetStats()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to reset VPN stats", e)
        }
    }

    private fun ensureVpnCore(): VPNService {
        val existing = vpnCore
        if (existing != null) {
            return existing
        }

        val runtimeRoot = File(noBackupFilesDir ?: filesDir, "vpncore")
        val workingDir = File(runtimeRoot, "working")
        val tempDir = File(cacheDir, "vpncore")
        runtimeRoot.mkdirs()
        workingDir.mkdirs()
        tempDir.mkdirs()

        val created = Gomobile.newVPNService().apply {
            setPlatform(this@PrivateDeployVpnService)
            configureRuntime(runtimeRoot.absolutePath, workingDir.absolutePath, tempDir.absolutePath)
            setFixAndroidStack(true)
            setUnderNetworkExtension(false)
            setIncludeAllNetworks(false)
            setUsePlatformAutoDetectInterfaceControl(true)
        }
        vpnCore = created
        return created
    }

    private fun cleanupTunnel() {
        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close VPN interface", e)
        } finally {
            vpnInterface = null
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "PrivateDeploy VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN connection status"
                setShowBadge(false)
            }

            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(contentText: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("PrivateDeploy VPN")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun statusMap(): Map<String, Any?> {
        val parsedStatus = parseJsonMap(vpnCore?.getStatus())?.toMutableMap()
        if (parsedStatus == null) {
            return mapOf(
                "running" to isRunning,
                "status" to if (isRunning) "connected" else "disconnected",
                "message" to null,
                "connected_at" to 0,
                "uptime" to 0
            )
        }

        val normalizedRunning = parseBooleanValue(parsedStatus["running"], isRunning)
        parsedStatus["running"] = normalizedRunning
        val statusValue = parsedStatus["status"]?.toString()?.trim()?.lowercase()
        parsedStatus["status"] = when {
            !statusValue.isNullOrBlank() -> statusValue
            normalizedRunning -> "connected"
            else -> "disconnected"
        }

        if (parsedStatus["status"] == "connected") {
            parsedStatus["running"] = true
        }

        return parsedStatus
    }

    private fun statsMap(): Map<String, Any?> {
        return parseJsonMap(vpnCore?.getStats()) ?: mapOf(
            "upload_bytes" to 0,
            "download_bytes" to 0,
            "upload_speed" to 0,
            "download_speed" to 0,
            "memory_bytes" to 0,
            "connections_in" to 0,
            "connections_out" to 0,
            "traffic_available" to false
        )
    }

    private fun parseJsonMap(json: String?): Map<String, Any?>? {
        if (json.isNullOrBlank()) {
            return null
        }

        val objectJson = JSONObject(json)
        val result = linkedMapOf<String, Any?>()
        val keys = objectJson.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = when (val value = objectJson.get(key)) {
                JSONObject.NULL -> null
                is Int, is Long, is Double, is Boolean, is String -> value
                else -> value.toString()
            }
        }
        return result
    }

    private fun parseBooleanValue(value: Any?, fallback: Boolean): Boolean {
        if (value == null) {
            return fallback
        }
        return when (value) {
            is Boolean -> value
            is Number -> value.toInt() != 0
            is String -> when (value.trim().lowercase()) {
                "true", "1", "yes", "y" -> true
                "false", "0", "no", "n" -> false
                else -> fallback
            }
            else -> fallback
        }
    }

    private fun broadcastStatus(status: String, message: String?) {
        sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
            setPackage(packageName)
            putExtra("status", status)
            putExtra("message", message)
        })
    }

    private fun broadcastError(message: String) {
        Log.e(TAG, message)
        broadcastStatus("error", message)
    }

    private fun broadcastLog(message: String, timestamp: Long) {
        appendRecentLog(message, timestamp)
        sendBroadcast(Intent(ACTION_VPN_LOG).apply {
            setPackage(packageName)
            putExtra("message", message)
            putExtra("timestamp", timestamp)
        })
    }

    override fun getNetworkInterfaces(): String {
        return try {
            val payload = JSONArray()
            collectUnderlyingInterfaces().forEach { snapshot ->
                payload.put(snapshot.toJson())
            }
            payload.toString()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to collect underlying interfaces", e)
            "[]"
        }
    }

    override fun onDestroy() {
        if (serviceInstance === this) {
            serviceInstance = null
        }
        super.onDestroy()
        Log.d(TAG, "VPN Service destroyed")
    }

    override fun onRevoke() {
        super.onRevoke()
        Log.w(TAG, "VPN permission revoked")
        broadcastStatus("revoked", VPN_REVOKED_MESSAGE)
        stopVpn()
    }

    override fun openTun(options: TunConfig?): Int {
        requireNotNull(options) { "TUN options are missing" }

        cleanupTunnel()

        val builder = Builder()
            .setSession("PrivateDeploy")
            .setMtu(options.getMTU())

        applyAddressList(builder, options.getInet4AddressList())
        applyAddressList(builder, options.getInet6AddressList())
        applyDns(builder, options.getDNSServerAddress())
        applyRouteList(builder, options.getRouteAddressList())
        applyExcludedRouteList(builder, options.getRouteExcludeAddressList())
        applyPackages(builder, options.getIncludePackageList(), options.getExcludePackageList())
        applyHttpProxy(builder, options)

        if (options.getAutoRoute() && options.getRouteAddressList().isBlank()) {
            builder.addRoute("0.0.0.0", 0)
            if (options.getInet6AddressList().isNotBlank()) {
                builder.addRoute("::", 0)
            }
        }

        val established = builder.establish()
            ?: throw IllegalStateException("Failed to establish VPN interface")

        vpnInterface = established
        return established.fd
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            throw IllegalStateException("Failed to protect socket fd=$fd")
        }
    }

    override fun writeLog(message: String?) {
        if (message.isNullOrBlank()) {
            return
        }
        Log.d(TAG, "[vpncore] $message")
        broadcastLog(message, System.currentTimeMillis())
    }

    private fun collectUnderlyingInterfaces(): List<InterfaceSnapshot> {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return emptyList()
        val defaultNetwork = findPreferredUnderlyingNetwork(connectivityManager)
        val snapshots = linkedMapOf<String, InterfaceSnapshot>()

        connectivityManager.allNetworks.forEach { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return@forEach
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return@forEach
            }
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                return@forEach
            }

            val linkProperties = connectivityManager.getLinkProperties(network) ?: return@forEach
            val interfaceName = linkProperties.interfaceName?.trim().orEmpty()
            if (interfaceName.isEmpty()) {
                return@forEach
            }

            snapshots[interfaceName] = buildInterfaceSnapshot(
                interfaceName = interfaceName,
                capabilities = capabilities,
                linkProperties = linkProperties,
                isDefault = network == defaultNetwork
            )
        }

        return snapshots.values.sortedByDescending { snapshot ->
            if (snapshot.isDefault) 1 else 0
        }
    }

    private fun findPreferredUnderlyingNetwork(connectivityManager: ConnectivityManager): Network? {
        val activeNetwork = connectivityManager.activeNetwork
        var bestNetwork: Network? = null
        var bestScore = Int.MIN_VALUE

        connectivityManager.allNetworks.forEach { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return@forEach
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return@forEach
            }
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                return@forEach
            }

            val linkProperties = connectivityManager.getLinkProperties(network) ?: return@forEach
            if (linkProperties.interfaceName.isNullOrBlank()) {
                return@forEach
            }

            var score = 0
            if (network == activeNetwork) {
                score += 1000
            }
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                score += 200
            }
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)) {
                score += 50
            }
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)) {
                score += 25
            }
            score += when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 30
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 20
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 10
                else -> 0
            }

            if (score > bestScore) {
                bestNetwork = network
                bestScore = score
            }
        }

        return bestNetwork
    }

    private fun buildInterfaceSnapshot(
        interfaceName: String,
        capabilities: NetworkCapabilities,
        linkProperties: android.net.LinkProperties,
        isDefault: Boolean
    ): InterfaceSnapshot {
        val networkInterface = runCatching { NetworkInterface.getByName(interfaceName) }.getOrNull()
        val addresses = linkProperties.linkAddresses
            .mapNotNull { linkAddress -> linkAddress?.toString() }
            .distinct()
        val dnsServers = linkProperties.dnsServers
            .mapNotNull { address -> address?.hostAddress ?: address?.toString() }
            .distinct()

        return InterfaceSnapshot(
            index = runCatching { networkInterface?.index ?: 0 }.getOrDefault(0),
            mtu = if (linkProperties.mtu > 0) linkProperties.mtu else 1500,
            name = interfaceName,
            addresses = addresses,
            flags = buildInterfaceFlags(networkInterface),
            type = determineInterfaceType(capabilities, interfaceName),
            dnsServers = dnsServers,
            metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            expensive = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            constrained = false,
            isDefault = isDefault
        )
    }

    private fun buildInterfaceFlags(networkInterface: NetworkInterface?): Int {
        val isUp = runCatching { networkInterface?.isUp != false }.getOrDefault(true)
        if (!isUp) {
            return 0
        }

        var flags = INTERFACE_FLAG_UP or INTERFACE_FLAG_RUNNING
        if (runCatching { networkInterface?.supportsMulticast() != false }.getOrDefault(true)) {
            flags = flags or INTERFACE_FLAG_MULTICAST
        }
        return flags
    }

    private fun determineInterfaceType(capabilities: NetworkCapabilities, interfaceName: String): Int {
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> INTERFACE_TYPE_WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> INTERFACE_TYPE_CELLULAR
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> INTERFACE_TYPE_ETHERNET
            else -> classifyInterfaceType(interfaceName)
        }
    }

    private fun classifyInterfaceType(interfaceName: String): Int {
        val normalized = interfaceName.trim().lowercase()
        return when {
            normalized.startsWith("wlan") || normalized.startsWith("wifi") || normalized.startsWith("swlan") || normalized.startsWith("ap") -> INTERFACE_TYPE_WIFI
            normalized.startsWith("rmnet") || normalized.startsWith("ccmni") || normalized.startsWith("pdp") || normalized.startsWith("wwan") || normalized.startsWith("cell") -> INTERFACE_TYPE_CELLULAR
            normalized.startsWith("eth") || normalized.startsWith("en") -> INTERFACE_TYPE_ETHERNET
            else -> INTERFACE_TYPE_OTHER
        }
    }

    private fun applyAddressList(builder: Builder, rawList: String) {
        for (cidr in parseLines(rawList)) {
            val (address, prefixLength) = splitCidr(cidr)
            builder.addAddress(address, prefixLength)
        }
    }

    private fun applyDns(builder: Builder, dnsServer: String) {
        val dns = dnsServer.trim()
        if (dns.isNotEmpty()) {
            builder.addDnsServer(dns)
        }
    }

    private fun applyRouteList(builder: Builder, rawList: String) {
        for (cidr in parseLines(rawList)) {
            val (address, prefixLength) = splitCidr(cidr)
            builder.addRoute(address, prefixLength)
        }
    }

    private fun applyExcludedRouteList(builder: Builder, rawList: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        for (cidr in parseLines(rawList)) {
            val (address, prefixLength) = splitCidr(cidr)
            builder.excludeRoute(IpPrefix(InetAddress.getByName(address), prefixLength))
        }
    }

    private fun applyPackages(builder: Builder, includePackages: String, excludePackages: String) {
        val includeList = parseLines(includePackages)
        val excludeList = parseLines(excludePackages)

        try {
            if (includeList.isNotEmpty()) {
                includeList.forEach(builder::addAllowedApplication)
            } else if (excludeList.isNotEmpty()) {
                excludeList.forEach(builder::addDisallowedApplication)
            }
        } catch (e: PackageManager.NameNotFoundException) {
            throw IllegalArgumentException("Unknown package in VPN rule list: ${e.message}", e)
        }
    }

    private fun applyHttpProxy(builder: Builder, options: TunConfig) {
        if (!options.isHTTPProxyEnabled()) {
            return
        }
        val server = options.getHTTPProxyServer().trim()
        val port = options.getHTTPProxyServerPort()
        if (server.isNotEmpty() && port > 0) {
            builder.setHttpProxy(ProxyInfo.buildDirectProxy(server, port))
        }
    }

    private fun parseLines(raw: String): List<String> {
        return raw
            .lines()
            .map(String::trim)
            .filter(String::isNotEmpty)
    }

    private fun splitCidr(cidr: String): Pair<String, Int> {
        val parts = cidr.split("/", limit = 2)
        require(parts.size == 2) { "Invalid CIDR: $cidr" }
        return parts[0] to parts[1].toInt()
    }

    private data class InterfaceSnapshot(
        val index: Int,
        val mtu: Int,
        val name: String,
        val addresses: List<String>,
        val flags: Int,
        val type: Int,
        val dnsServers: List<String>,
        val metered: Boolean,
        val expensive: Boolean,
        val constrained: Boolean,
        val isDefault: Boolean,
    ) {
        fun toJson(): JSONObject {
            return JSONObject().apply {
                put("index", index)
                put("mtu", mtu)
                put("name", name)
                put("flags", flags)
                put("type", type)
                put("metered", metered)
                put("expensive", expensive)
                put("constrained", constrained)
                put("is_default", isDefault)
                put("addresses", JSONArray(addresses))
                put("dns_servers", JSONArray(dnsServers))
            }
        }
    }

    private data class RuntimeLogRecord(
        val timestamp: Long,
        val message: String,
    )
}

const val ACTION_START = "com.privatedeploy.mobile.START_VPN"
const val ACTION_STOP = "com.privatedeploy.mobile.STOP_VPN"
const val ACTION_RESTART = "com.privatedeploy.mobile.RESTART_VPN"
const val ACTION_UPDATE_CONFIG = "com.privatedeploy.mobile.UPDATE_VPN_CONFIG"
const val ACTION_RESET_STATS = "com.privatedeploy.mobile.RESET_VPN_STATS"
const val ACTION_VPN_STATUS = "com.privatedeploy.mobile.VPN_STATUS"
const val ACTION_VPN_LOG = "com.privatedeploy.mobile.VPN_LOG"

const val EXTRA_CONFIG = "config"
