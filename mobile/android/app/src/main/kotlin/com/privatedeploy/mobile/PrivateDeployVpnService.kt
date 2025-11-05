package com.privatedeploy.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * PrivateDeploy VPN Service
 *
 * 实现 Android VPN 功能的核心服务
 * 使用 VpnService API 创建 TUN 接口并路由流量到 Go 核心
 */
class PrivateDeployVpnService : VpnService() {

    companion object {
        private const val TAG = "PrivateDeployVPN"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "PrivateDeployVPN"
        private const val VPN_MTU = 1500
        private const val VPN_ADDRESS = "10.0.0.2"
        private const val VPN_ROUTE = "0.0.0.0"

        // VPN 状态
        var isRunning = false
            private set
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var vpnThread: Thread? = null

    // Go Mobile VPN Core (将在集成 gomobile 后使用)
    // private var vpnCore: VPNService? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "VPN Service created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                startVpn(config ?: "")
            }
            ACTION_STOP -> {
                stopVpn()
            }
        }
        return START_STICKY
    }

    /**
     * 启动 VPN 连接
     */
    private fun startVpn(config: String) {
        if (isRunning) {
            Log.w(TAG, "VPN is already running")
            return
        }

        try {
            Log.i(TAG, "Starting VPN...")

            // 配置 VPN 接口
            val builder = Builder()
                .setSession("PrivateDeploy")
                .addAddress(VPN_ADDRESS, 24)
                .addRoute(VPN_ROUTE, 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("8.8.4.4")
                .setMtu(VPN_MTU)
                .setBlocking(false)

            // 创建 VPN 接口
            vpnInterface = builder.establish()

            if (vpnInterface == null) {
                Log.e(TAG, "Failed to establish VPN interface")
                sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
                    putExtra("status", "error")
                    putExtra("message", "Failed to establish VPN interface")
                })
                return
            }

            isRunning = true

            // 启动前台服务通知
            startForeground(NOTIFICATION_ID, createNotification())

            // TODO: 集成 Go Mobile VPN Core
            // vpnCore = VPNService()
            // vpnCore?.start(config)

            // 启动数据包处理线程
            startPacketLoop()

            Log.i(TAG, "VPN started successfully")
            sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
                putExtra("status", "connected")
            })

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN", e)
            stopVpn()
            sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
                putExtra("status", "error")
                putExtra("message", e.message)
            })
        }
    }

    /**
     * 停止 VPN 连接
     */
    private fun stopVpn() {
        Log.i(TAG, "Stopping VPN...")

        try {
            // 停止数据包处理线程
            vpnThread?.interrupt()
            vpnThread = null

            // TODO: 停止 Go Mobile VPN Core
            // vpnCore?.stop()
            // vpnCore = null

            // 关闭 VPN 接口
            vpnInterface?.close()
            vpnInterface = null

            isRunning = false

            // 停止前台服务
            stopForeground(STOP_FOREGROUND_REMOVE)

            Log.i(TAG, "VPN stopped")
            sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
                putExtra("status", "disconnected")
            })

        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN", e)
        }
    }

    /**
     * 启动数据包处理循环
     */
    private fun startPacketLoop() {
        vpnThread = thread(start = true, name = "VPN-Packet-Loop") {
            try {
                val fd = vpnInterface?.fileDescriptor ?: return@thread
                val inputStream = FileInputStream(fd)
                val outputStream = FileOutputStream(fd)
                val buffer = ByteBuffer.allocate(32767)

                Log.d(TAG, "Packet loop started")

                while (!Thread.currentThread().isInterrupted && isRunning) {
                    try {
                        // 读取数据包
                        val length = inputStream.read(buffer.array())
                        if (length > 0) {
                            buffer.limit(length)

                            // TODO: 将数据包传递给 Go Mobile VPN Core 处理
                            // vpnCore?.handlePacket(buffer.array(), length)

                            // 当前简单示例：直接回环（实际应该由 Go Core 处理）
                            // outputStream.write(buffer.array(), 0, length)

                            buffer.clear()
                        }
                    } catch (e: Exception) {
                        if (Thread.currentThread().isInterrupted) break
                        Log.e(TAG, "Error in packet loop", e)
                    }
                }

                Log.d(TAG, "Packet loop stopped")

            } catch (e: Exception) {
                Log.e(TAG, "Packet loop exception", e)
            }
        }
    }

    /**
     * 创建通知渠道
     */
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

    /**
     * 创建前台服务通知
     */
    private fun createNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("PrivateDeploy VPN")
            .setContentText("VPN is connected")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "VPN Service destroyed")
        stopVpn()
    }

    override fun onRevoke() {
        super.onRevoke()
        Log.w(TAG, "VPN permission revoked")
        stopVpn()
        sendBroadcast(Intent(ACTION_VPN_STATUS).apply {
            putExtra("status", "revoked")
        })
    }
}

// Intent Actions
const val ACTION_START = "com.privatedeploy.mobile.START_VPN"
const val ACTION_STOP = "com.privatedeploy.mobile.STOP_VPN"
const val ACTION_VPN_STATUS = "com.privatedeploy.mobile.VPN_STATUS"

// Intent Extras
const val EXTRA_CONFIG = "config"
