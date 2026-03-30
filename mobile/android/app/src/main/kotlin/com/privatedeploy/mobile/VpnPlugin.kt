package com.privatedeploy.mobile

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Patterns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

/**
 * VPN Plugin for Flutter
 *
 * 处理 Flutter 和 Android VPN Service 之间的通信
 */
class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "VpnPlugin"
        private const val METHOD_CHANNEL = "com.privatedeploy.vpn/native"
        private const val EVENT_CHANNEL = "com.privatedeploy.vpn/events"
        private const val VPN_REQUEST_CODE = 100
        private const val START_TIMEOUT_MS = 30000L
        private const val EGRESS_PROBE_TIMEOUT_MS = 1500
        private val EGRESS_PROBE_ENDPOINTS = listOf(
            NativeEgressProbeEndpoint("http://1.1.1.1/cdn-cgi/trace"),
            NativeEgressProbeEndpoint("http://1.0.0.1/cdn-cgi/trace"),
            NativeEgressProbeEndpoint("https://api.ipify.org?format=json"),
            NativeEgressProbeEndpoint("https://ifconfig.me/ip"),
        )
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var activity: Activity? = null
    private var context: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStartConfig: String? = null
    private var pendingStartDispatched = false
    private var pendingStartTimeout: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val vpnStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_VPN_STATUS -> {
                    val status = intent.getStringExtra("status")
                    val message = intent.getStringExtra("message")

                    eventSink?.success(
                        mapOf(
                            "type" to "status",
                            "data" to mapOf(
                                "running" to (status == "connected"),
                                "status" to status,
                                "message" to message
                            )
                        )
                    )

                    when (status) {
                        "connected" -> completePendingStart()
                        "error" -> failPendingStart(
                            code = "START_FAILED",
                            message = message ?: "Failed to start VPN"
                        )
                        "revoked" -> failPendingStart(
                            code = "PERMISSION_REVOKED",
                            message = "VPN permission revoked"
                        )
                        "disconnected" -> {
                            if (pendingStartResult != null && !message.isNullOrBlank()) {
                                failPendingStart(
                                    code = "START_FAILED",
                                    message = message
                                )
                            } else if (pendingStartResult != null) {
                                Log.i(
                                    TAG,
                                    "Ignoring stale disconnected status while a new VPN start is pending"
                                )
                            }
                        }
                    }
                }
                ACTION_VPN_LOG -> {
                    val message = intent.getStringExtra("message")
                    val timestamp = intent.getLongExtra(
                        "timestamp",
                        System.currentTimeMillis()
                    )

                    if (!message.isNullOrBlank()) {
                        eventSink?.success(
                            mapOf(
                                "type" to "log",
                                "data" to mapOf(
                                    "message" to message,
                                    "timestamp" to timestamp,
                                )
                            )
                        )
                    }
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)

        Log.d(TAG, "VPN Plugin attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context = null
        Log.d(TAG, "VPN Plugin detached from engine")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)

        // 注册 VPN 状态广播接收器
        val receiverFilter = IntentFilter().apply {
            addAction(ACTION_VPN_STATUS)
            addAction(ACTION_VPN_LOG)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context?.registerReceiver(
                vpnStatusReceiver,
                receiverFilter,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            context?.registerReceiver(
                vpnStatusReceiver,
                receiverFilter
            )
        }

        Log.d(TAG, "VPN Plugin attached to activity")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        try {
            context?.unregisterReceiver(vpnStatusReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Error unregistering receiver", e)
        }
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> stopVpn(result)
            "restartVpn" -> restartVpn(result)
            "getCapabilities" -> getCapabilities(result)
            "isRunning" -> isRunning(result)
            "getStatus" -> getStatus(result)
            "getStats" -> getStats(result)
            "getRecentLogs" -> getRecentLogs(result)
            "getEgressIp" -> getEgressIp(result)
            "resetStats" -> resetStats(result)
            "updateConfig" -> updateConfig(call, result)
            "getVersion" -> getVersion(result)
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun getCapabilities(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "supported" to true,
                "reason" to null,
            )
        )
    }

    /**
     * 启动 VPN
     */
    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""
        if (config.isBlank()) {
            result.error("INVALID_CONFIG", "VPN config is empty", null)
            return
        }

        // Pre-validate config JSON structure
        try {
            val json = org.json.JSONObject(config)
            val outbounds = json.optJSONArray("outbounds")
            if (outbounds == null || outbounds.length() == 0) {
                result.error("INVALID_CONFIG", "Invalid config: missing or empty \"outbounds\" section", null)
                return
            }
        } catch (e: Exception) {
            result.error("INVALID_CONFIG", "Invalid config: not valid JSON - ${e.message}", null)
            return
        }

        if (pendingStartResult != null) {
            result.error("START_IN_PROGRESS", "VPN start already in progress", null)
            return
        }

        pendingStartResult = result
        pendingStartConfig = config
        pendingStartDispatched = false

        val intent = VpnService.prepare(context)
        if (intent != null) {
            val currentActivity = activity
            if (currentActivity == null) {
                failPendingStart("NO_ACTIVITY", "Activity unavailable for VPN permission request")
                return
            }
            currentActivity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            launchPendingStart(config)
        }
    }

    /**
     * 执行启动 VPN
     */
    private fun doStartVpn(config: String) {
        val intent = Intent(context, PrivateDeployVpnService::class.java).apply {
            action = ACTION_START
            putExtra(EXTRA_CONFIG, config)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context?.startForegroundService(intent)
        } else {
            context?.startService(intent)
        }

        Log.i(TAG, "VPN start command sent")
    }

    private fun launchPendingStart(config: String) {
        schedulePendingStartTimeout()
        try {
            doStartVpn(config)
            pendingStartDispatched = true
        } catch (e: Exception) {
            failPendingStart(
                code = "START_FAILED",
                message = e.message ?: "Failed to dispatch VPN start request"
            )
        }
    }

    private fun schedulePendingStartTimeout() {
        pendingStartTimeout?.let(mainHandler::removeCallbacks)
        val timeoutRunnable = Runnable {
            if (pendingStartResult != null) {
                failPendingStart(
                    code = "START_TIMEOUT",
                    message = "Timed out waiting for VPN to connect"
                )
            }
        }
        pendingStartTimeout = timeoutRunnable
        mainHandler.postDelayed(timeoutRunnable, START_TIMEOUT_MS)
    }

    private fun completePendingStart() {
        val result = pendingStartResult ?: return
        clearPendingStart()
        result.success(true)
    }

    private fun failPendingStart(code: String, message: String) {
        val shouldStopVpn = pendingStartDispatched
        val result = pendingStartResult ?: return
        clearPendingStart()
        if (shouldStopVpn) {
            sendVpnAction(ACTION_STOP)
        }
        result.error(code, message, null)
    }

    private fun clearPendingStart() {
        pendingStartTimeout?.let(mainHandler::removeCallbacks)
        pendingStartTimeout = null
        pendingStartResult = null
        pendingStartConfig = null
        pendingStartDispatched = false
    }

    /**
     * 停止 VPN
     */
    private fun stopVpn(result: MethodChannel.Result) {
        sendVpnAction(ACTION_STOP)
        result.success(true)
        Log.i(TAG, "VPN stop command sent")
    }

    /**
     * 重启 VPN
     */
    private fun restartVpn(result: MethodChannel.Result) {
        sendVpnAction(ACTION_RESTART)
        result.success(true)
        Log.i(TAG, "VPN restart command sent")
    }

    /**
     * 检查 VPN 是否运行
     */
    private fun isRunning(result: MethodChannel.Result) {
        result.success(PrivateDeployVpnService.isRunning)
    }

    /**
     * 获取 VPN 状态
     */
    private fun getStatus(result: MethodChannel.Result) {
        result.success(PrivateDeployVpnService.currentStatus())
    }

    /**
     * 获取流量统计
     */
    private fun getStats(result: MethodChannel.Result) {
        result.success(PrivateDeployVpnService.currentStats())
    }

    private fun getRecentLogs(result: MethodChannel.Result) {
        result.success(PrivateDeployVpnService.currentRecentLogs())
    }

    private fun getEgressIp(result: MethodChannel.Result) {
        Thread {
            val probeResult = probeEgressIp()
            mainHandler.post {
                result.success(
                    mapOf(
                        "ip" to probeResult.ip,
                        "source" to probeResult.source,
                        "error" to probeResult.error,
                    )
                )
            }
        }.start()
    }

    /**
     * 重置统计
     */
    private fun resetStats(result: MethodChannel.Result) {
        sendVpnAction(ACTION_RESET_STATS)
        result.success(true)
    }

    /**
     * 更新配置
     */
    private fun updateConfig(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""
        if (config.isBlank()) {
            result.error("INVALID_CONFIG", "VPN config is empty", null)
            return
        }
        sendVpnAction(ACTION_UPDATE_CONFIG) {
            putExtra(EXTRA_CONFIG, config)
        }
        result.success(true)
    }

    private fun sendVpnAction(action: String, extras: (Intent.() -> Unit)? = null) {
        val intent = Intent(context, PrivateDeployVpnService::class.java).apply {
            this.action = action
            extras?.invoke(this)
        }
        context?.startService(intent)
    }

    /**
     * 获取版本
     */
    private fun getVersion(result: MethodChannel.Result) {
        result.success(PrivateDeployVpnService.currentVersion())
    }

    /**
     * 请求 VPN 权限
     */
    private fun requestPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(context)
        if (intent != null) {
            if (pendingPermissionResult != null) {
                result.error("PERMISSION_REQUEST_IN_PROGRESS", "VPN permission request already in progress", null)
                return
            }
            val currentActivity = activity
            if (currentActivity == null) {
                result.error("NO_ACTIVITY", "Activity unavailable for VPN permission request", null)
                return
            }
            pendingPermissionResult = result
            currentActivity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            pendingPermissionResult?.let { result ->
                if (resultCode == Activity.RESULT_OK) {
                    result.success(true)
                    Log.i(TAG, "VPN permission granted")
                } else {
                    result.success(false)
                    Log.w(TAG, "VPN permission denied")
                }
                pendingPermissionResult = null
                return true
            }

            if (pendingStartResult != null) {
                if (resultCode == Activity.RESULT_OK) {
                    val config = pendingStartConfig
                    if (!config.isNullOrBlank()) {
                        launchPendingStart(config)
                    } else {
                        failPendingStart("INVALID_CONFIG", "VPN config is empty")
                    }
                    Log.i(TAG, "VPN permission granted")
                } else {
                    failPendingStart("PERMISSION_DENIED", "VPN permission denied")
                    Log.w(TAG, "VPN permission denied")
                }
                return true
            }
        }
        return false
    }

    // EventChannel.StreamHandler implementation
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        Log.d(TAG, "Event stream listener attached")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        Log.d(TAG, "Event stream listener cancelled")
    }

    private data class NativeEgressProbeResult(
        val ip: String? = null,
        val source: String? = null,
        val error: String? = null,
    )

    private data class NativeEgressProbeEndpoint(
        val url: String,
        val hostHeader: String? = null,
    )

    private fun probeEgressIp(): NativeEgressProbeResult {
        var lastError: String? = null

        for (endpoint in EGRESS_PROBE_ENDPOINTS) {
            try {
                val payload = fetchProbePayload(endpoint)
                val ip = extractIpFromProbePayload(payload)
                if (!ip.isNullOrBlank()) {
                    Log.i(TAG, "VPN egress probe succeeded via ${endpoint.url} -> $ip")
                    return NativeEgressProbeResult(ip = ip, source = endpoint.url)
                }
                Log.w(TAG, "VPN egress probe returned unparseable payload from ${endpoint.url}")
                lastError = "Public IP probe returned an unexpected response."
            } catch (timeout: SocketTimeoutException) {
                Log.w(TAG, "VPN egress probe timed out for ${endpoint.url}", timeout)
                lastError = "Timed out contacting public IP probe endpoints."
            } catch (error: Exception) {
                Log.w(TAG, "VPN egress probe failed for ${endpoint.url}", error)
                lastError = "Could not reach public IP probe endpoints through the current VPN route."
            }
        }

        return NativeEgressProbeResult(error = lastError ?: "Unable to determine current egress IP.")
    }

    private fun fetchProbePayload(endpoint: NativeEgressProbeEndpoint): String {
        val url = URL(endpoint.url)
        val connection = openProbeConnection(url)
        try {
            connection.instanceFollowRedirects = true
            connection.connectTimeout = EGRESS_PROBE_TIMEOUT_MS
            connection.readTimeout = EGRESS_PROBE_TIMEOUT_MS
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json, text/plain;q=0.9, */*;q=0.8")
            connection.setRequestProperty("User-Agent", "PrivateDeploy/1.0")
            endpoint.hostHeader?.let { connection.setRequestProperty("Host", it) }
            connection.connect()

            val statusCode = connection.responseCode
            if (statusCode !in 200..399) {
                throw IllegalStateException("Unexpected HTTP status $statusCode from ${endpoint.url}")
            }

            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun openProbeConnection(url: URL): HttpURLConnection {
        val connectivityManager =
            context?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val activeNetwork = connectivityManager?.activeNetwork
        val connection = if (activeNetwork != null) {
            activeNetwork.openConnection(url)
        } else {
            url.openConnection()
        }

        return connection as? HttpURLConnection
            ?: throw IllegalStateException("Unsupported probe connection type for $url")
    }

    private fun extractIpFromProbePayload(payload: String): String? {
        val trimmed = payload.trim()
        if (trimmed.isEmpty()) {
            return null
        }

        try {
            val json = org.json.JSONObject(trimmed)
            for (key in listOf("ip", "ip_addr", "address")) {
                val candidate = json.optString(key).trim()
                if (isLiteralIp(candidate)) {
                    return candidate
                }
            }
        } catch (_: Exception) {
        }

        Regex("^ip=([^\\s]+)$", RegexOption.MULTILINE)
            .find(trimmed)
            ?.groupValues
            ?.getOrNull(1)
            ?.trim()
            ?.takeIf(::isLiteralIp)
            ?.let { return it }

        val firstLine = trimmed.lineSequence().firstOrNull()?.trim()
        if (isLiteralIp(firstLine)) {
            return firstLine
        }

        return null
    }

    private fun isLiteralIp(candidate: String?): Boolean {
        val value = candidate?.trim()
        if (value.isNullOrEmpty()) {
            return false
        }
        return Patterns.IP_ADDRESS.matcher(value).matches()
    }
}
