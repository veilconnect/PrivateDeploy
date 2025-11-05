package com.privatedeploy.mobile

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

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
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var activity: Activity? = null
    private var context: Context? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingResult: MethodChannel.Result? = null

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context?.registerReceiver(
                vpnStatusReceiver,
                IntentFilter(ACTION_VPN_STATUS),
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            context?.registerReceiver(
                vpnStatusReceiver,
                IntentFilter(ACTION_VPN_STATUS)
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
            "isRunning" -> isRunning(result)
            "getStatus" -> getStatus(result)
            "getStats" -> getStats(result)
            "resetStats" -> resetStats(result)
            "updateConfig" -> updateConfig(call, result)
            "getVersion" -> getVersion(result)
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 启动 VPN
     */
    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""

        // 检查 VPN 权限
        val intent = VpnService.prepare(context)
        if (intent != null) {
            // 需要请求权限
            pendingResult = result
            activity?.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            // 已有权限，直接启动
            doStartVpn(config)
            result.success(true)
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

    /**
     * 停止 VPN
     */
    private fun stopVpn(result: MethodChannel.Result) {
        val intent = Intent(context, PrivateDeployVpnService::class.java).apply {
            action = ACTION_STOP
        }
        context?.startService(intent)
        result.success(true)
        Log.i(TAG, "VPN stop command sent")
    }

    /**
     * 重启 VPN
     */
    private fun restartVpn(result: MethodChannel.Result) {
        // 先停止再启动
        val stopIntent = Intent(context, PrivateDeployVpnService::class.java).apply {
            action = ACTION_STOP
        }
        context?.startService(stopIntent)

        // 延迟启动
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val startIntent = Intent(context, PrivateDeployVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, "")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context?.startForegroundService(startIntent)
            } else {
                context?.startService(startIntent)
            }
        }, 1000)

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
        val status = mapOf(
            "running" to PrivateDeployVpnService.isRunning,
            "connected_at" to 0,
            "uptime" to 0
        )
        result.success(status)
    }

    /**
     * 获取流量统计
     */
    private fun getStats(result: MethodChannel.Result) {
        // TODO: 从 Go Mobile VPN Core 获取实际统计数据
        val stats = mapOf(
            "upload_bytes" to 0,
            "download_bytes" to 0,
            "upload_speed" to 0,
            "download_speed" to 0
        )
        result.success(stats)
    }

    /**
     * 重置统计
     */
    private fun resetStats(result: MethodChannel.Result) {
        // TODO: 重置 Go Mobile VPN Core 的统计数据
        result.success(true)
    }

    /**
     * 更新配置
     */
    private fun updateConfig(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""
        // TODO: 更新配置
        result.success(true)
    }

    /**
     * 获取版本
     */
    private fun getVersion(result: MethodChannel.Result) {
        result.success("PrivateDeploy VPN Android 1.0.0")
    }

    /**
     * 请求 VPN 权限
     */
    private fun requestPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(context)
        if (intent != null) {
            pendingResult = result
            activity?.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            pendingResult?.let { result ->
                if (resultCode == Activity.RESULT_OK) {
                    // 权限已授予
                    result.success(true)
                    Log.i(TAG, "VPN permission granted")
                } else {
                    // 权限被拒绝
                    result.success(false)
                    Log.w(TAG, "VPN permission denied")
                }
                pendingResult = null
            }
            return true
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
}
