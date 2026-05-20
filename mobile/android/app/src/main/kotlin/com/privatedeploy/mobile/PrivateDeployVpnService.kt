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
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
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
        private const val UNDERLYING_NETWORK_RESTART_DEBOUNCE_MS = 300L
        private const val MIN_UNDERLYING_NETWORK_RESTART_INTERVAL_MS = 4000L
        // Bumped from 2 → 4. With exponential backoff (1.5 / 3 / 6 / 12 s ≈
        // 22.5 s total) we cover network-validation jitter on Chinese
        // carriers without giving up prematurely during a fast Wi-Fi ↔
        // cellular oscillation. 2 attempts at 1.5 + 3 = 4.5 s left zero
        // headroom if the new transport took >5 s to settle and the
        // gate-fix below means a future NetworkCallback can still recover,
        // but recovery is cheaper than a user-visible disconnect blink.
        private const val RESTART_MAX_ATTEMPTS = 4
        private const val RESTART_RETRY_BASE_DELAY_MS = 1500L
        private const val START_MAX_ATTEMPTS = 2
        private const val START_RETRY_BASE_DELAY_MS = 1500L
        // Wait up to 12 s for the new transport to reach
        // NET_CAPABILITY_VALIDATED before kicking off start/restart.
        // Real-world mobile networks (mobile carrier / Telecom / Unicom)
        // commonly need 5–10 s to complete the captive-portal probe; the
        // earlier 4 s cap returned too often before validation, leaving
        // sing-box bound to a half-baked upstream and producing the
        // "tunnel up but nothing flows" symptom.
        private const val VALIDATED_NETWORK_WAIT_MS = 12000L
        // If the carrier blocks Android's captive-portal probe entirely
        // (NET_CAPABILITY_VALIDATED never arrives) but a usable
        // INTERNET-capable transport is present, accept it after this
        // shorter window so we don't deadlock until VALIDATED_NETWORK_WAIT_MS.
        private const val UNVALIDATED_NETWORK_FALLBACK_MS = 6000L
        // Per-endpoint timeout for the post-connect health probe. Each
        // checkTunnelHealth() call issues up to EGRESS_VERIFY_UPSTREAM_REPEATS
        // TUNNEL_REQUIRED probes (gstatic /generate_204) followed, only on
        // failure, by one REACHABILITY probe (baidu/qq favicon), so the
        // worst-case wall time is roughly REPEATS × this constant + one more.
        private const val EGRESS_VERIFY_PROBE_TIMEOUT_MS = 2500

        // How often the post-connect health monitor re-runs checkTunnelHealth().
        // Long enough to keep the periodic network cost negligible (~one HTTP
        // sweep every 30 s) and to ride out short post-handover blips without
        // flapping the UI, short enough that a real persistent direct-route
        // failure surfaces within one cycle.
        private const val HEALTH_MONITOR_INTERVAL_MS = 30_000L

        // Number of consecutive TUNNEL_REQUIRED successes required to call the
        // upstream Healthy. Carriers (notably mobile carrier / Telecom / Unicom)
        // routinely let the first SYN or two from a flagged VPS slip through
        // their DPI engine before they start RST'ing connections, so a
        // single-shot gstatic probe can squeak through during that grace
        // window even when sustained traffic is broken — exactly the
        // scenario that produced the "VPN connected but YouTube doesn't
        // load" report. Three consecutive successes spaced ~600ms apart
        // bridges past that grace window without making startup feel sluggish
        // (~5s extra in the worst healthy case, much less when the first
        // probe fails fast).
        private const val EGRESS_VERIFY_UPSTREAM_REPEATS = 3
        private const val EGRESS_VERIFY_UPSTREAM_REPEAT_DELAY_MS = 600L
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

        private fun runtimeLogPriority(message: String): Int? {
            val plain = stripAnsi(message)
            return when {
                plain.contains("ERROR[", ignoreCase = true) -> Log.ERROR
                plain.contains("WARN[", ignoreCase = true) -> Log.WARN
                plain.contains("INFO[", ignoreCase = true) -> Log.INFO
                plain.contains("DEBUG[", ignoreCase = true) -> Log.DEBUG
                else -> null
            }
        }

        private fun shouldMirrorRuntimeLogToLogcat(message: String): Boolean {
            val plain = stripAnsi(message)
            val priority = runtimeLogPriority(plain)
            if (priority == null || priority >= Log.WARN) {
                if (isBenignAndroidPrivateDnsProbeLog(plain) ||
                    isBenignAndroidProcessLookupLog(plain)
                ) {
                    return false
                }
                return true
            }

            // Per-connection INFO/DEBUG chatter should stay available to the
            // in-app diagnostics parser, but does not need to flood logcat.
            return !isBenignAndroidPrivateDnsProbeLog(plain) &&
                !isBenignAndroidProcessLookupLog(plain) &&
                !plain.contains("outbound/", ignoreCase = true) &&
                !plain.contains("inbound/", ignoreCase = true) &&
                !plain.contains("dns: exchanged", ignoreCase = true)
        }

        private fun isBenignAndroidPrivateDnsProbeLog(message: String): Boolean {
            return message.contains(
                "connection: open outbound connection: operation not permitted",
                ignoreCase = true,
            )
        }

        private fun isBenignAndroidProcessLookupLog(message: String): Boolean {
            return message.contains(
                "router: failed to search process: invalid argument",
                ignoreCase = true,
            )
        }

        private fun stripAnsi(message: String): String {
            return message.replace(Regex("\\u001B\\[[;\\d]*m"), "")
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
    // Most recent diagnostic message broadcast to dart. Persisted here so that
    // dart's polling getStatus() path returns the same UpstreamDegraded text
    // the broadcast carried — without this, polling reads vpnCore.getStatus()
    // (which only knows about libbox-internal state) and overwrites the
    // dart-side _error to null, hiding the orange "switch nodes" warning
    // banner moments after the user connects to a blocked node.
    @Volatile
    private var latestStatusMessage: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var underlyingNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var pendingUnderlyingNetworkRestart: Runnable? = null
    private var lastObservedUnderlyingNetworkHandle: Long? = null
    private var lastObservedUnderlyingNetworkType: Int? = null
    // Tracks what we last actually pushed to setUnderlyingNetworks. Distinct
    // from lastObserved* (which tracks what NetworkCallback has told us about
    // the world) — this lets applyUnderlyingNetworks() skip framework calls
    // when the desired state matches what we already published. NetworkCallback
    // can fire repeatedly during airplane-mode flaps with the same end state,
    // and each redundant publish makes the framework re-attribute every VPN
    // socket for nothing.
    private var lastPublishedUnderlyingNetworkHandle: Long? = null
    private var lastPublishedUnderlyingNetworkPublished: Boolean = false
    @Volatile
    private var restartInProgress = false
    private var lastUnderlyingRestartAtMs = 0L

    override fun onCreate() {
        super.onCreate()
        serviceInstance = this
        createNotificationChannel()
        registerUnderlyingNetworkMonitor()
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

        val runtimeConfig = try {
            prepareConfigForRuntime(config)
        } catch (e: Exception) {
            broadcastError("Invalid config: not valid JSON - ${e.message}")
            return
        }

        // Pre-validate config JSON structure before passing to Go runtime
        try {
            val json = JSONObject(runtimeConfig)
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

        activeConfig = runtimeConfig
        clearRecentLogs()
        startForeground(NOTIFICATION_ID, createNotification("VPN is connecting"))
        broadcastStatus("connecting", null)

        thread(name = "PrivateDeploy-VPN-Start") {
            // Users tend to tap Connect right after a Wi-Fi ↔ cellular hand-off
            // (e.g. stepping out of range), which historically produced an
            // immediate failure because the default network wasn't yet
            // VALIDATED. Wait briefly for a usable transport to avoid making
            // them retry manually.
            waitForUsableUnderlyingNetwork(
                validatedTimeoutMs = VALIDATED_NETWORK_WAIT_MS,
                unvalidatedFallbackMs = UNVALIDATED_NETWORK_FALLBACK_MS,
            )

            var lastError: Throwable? = null
            var succeeded = false

            for (attempt in 1..START_MAX_ATTEMPTS) {
                try {
                    if (attempt > 1) {
                        startForeground(
                            NOTIFICATION_ID,
                            createNotification("VPN is connecting (retry $attempt)"),
                        )
                        broadcastStatus("connecting", null)
                    }
                    val core = ensureVpnCore()
                    if (attempt == 1 || !isRunning) {
                        core.start(runtimeConfig)
                    } else {
                        // The first attempt's start() succeeded internally even
                        // when the egress probe later failed (otherwise we'd be
                        // in the catch branch). Use restart() on subsequent
                        // attempts so libbox cleanly tears down stale upstream
                        // sockets bound to the now-defunct underlying network.
                        core.restart()
                    }
                    isRunning = true
                    captureCurrentUnderlyingNetworkSnapshot()

                    updateForegroundNotification("VPN connected (verifying)")

                    val health = checkTunnelHealth()
                    when (health) {
                        TunnelHealth.Healthy -> {
                            val outcome = describeTunnelHealth(health)
                            updateForegroundNotification(outcome.notificationText)
                            broadcastStatus("connected", outcome.statusMessage)
                            succeeded = true
                            Log.i(TAG, "VPN started successfully on attempt $attempt")
                        }
                        TunnelHealth.UpstreamDegraded -> {
                            val onCellular = lastObservedUnderlyingNetworkType ==
                                INTERFACE_TYPE_CELLULAR
                            if (onCellular) {
                                // Reported 2026-05-20: on mobile carrier cellular,
                                // every upstream node was SYN-dropped while
                                // baidu/qq stayed reachable through the direct
                                // outbound. checkTunnelHealth correctly returned
                                // UpstreamDegraded — but accepting that as
                                // `succeeded = true` left tun0 owning 0.0.0.0/0,
                                // which black-holed *every* offshore request
                                // from every app on the device. The user had to
                                // force-stop PrivateDeploy to get back online.
                                // Treat cellular UpstreamDegraded as a failed
                                // start: tear down the tun, broadcast the
                                // connectivity failure error (which fires Gate ③ banner
                                // + Gate ① auto-CDN-deploy on the Dart side),
                                // and let direct cellular traffic continue
                                // working until the user (or auto-deploy) sets
                                // CDN up.
                                //
                                // Tear down the tun NOW (not at end of loop)
                                // and break: attempt 2 against the same node
                                // on the same underlying network would just
                                // re-create the black-hole tun for the
                                // backoff+retry window.
                                lastError = IllegalStateException(
                                    cellularCarrierSynBlockMessage(),
                                )
                                Log.w(
                                    TAG,
                                    "VPN start attempt $attempt: cellular " +
                                        "UpstreamDegraded — refusing to install " +
                                        "a black-hole tun. User likely needs " +
                                        "CDN acceleration; banner + auto-deploy " +
                                        "will fire on the Dart side. Tearing " +
                                        "down tun immediately and skipping retry.",
                                )
                                try {
                                    vpnCore?.stop()
                                } catch (e: Exception) {
                                    Log.w(TAG, "stop() during synblock refuse failed", e)
                                }
                                cleanupTunnel()
                                isRunning = false
                                break
                            } else {
                                val outcome =
                                    degradedOutcomeForCurrentTransport(health)
                                updateForegroundNotification(outcome.notificationText)
                                broadcastStatus("connected", outcome.statusMessage)
                                succeeded = true
                                Log.w(
                                    TAG,
                                    "VPN start attempt $attempt: tunnel up but upstream " +
                                        "unreachable; the configured node looks blocked " +
                                        "from this network — user should switch nodes",
                                )
                            }
                        }
                        TunnelHealth.DirectRouteDegraded -> {
                            val outcome = describeTunnelHealth(health)
                            updateForegroundNotification(outcome.notificationText)
                            broadcastStatus("connected", outcome.statusMessage)
                            succeeded = true
                            Log.w(
                                TAG,
                                "VPN start attempt $attempt: upstream OK but direct " +
                                    "route still settling; accepting with degraded " +
                                    "indicator — periodic monitor will clear it once " +
                                    "domestic probes start passing",
                            )
                        }
                        TunnelHealth.Unreachable -> {
                            lastError = IllegalStateException(startupConnectivityFailureMessage())
                            Log.w(
                                TAG,
                                "VPN start attempt $attempt: probe couldn't reach any " +
                                    "endpoint through the tunnel; treating this as a " +
                                    "failed start so the app does not leave a blackholed " +
                                    "TUN route installed",
                            )
                        }
                    }
                    if (succeeded) {
                        startHealthMonitor()
                        break
                    }
                } catch (e: Throwable) {
                    Log.w(
                        TAG,
                        "VPN start attempt $attempt/$START_MAX_ATTEMPTS failed: ${e.message}",
                        e,
                    )
                    lastError = e
                }

                if (attempt < START_MAX_ATTEMPTS) {
                    val backoff = START_RETRY_BASE_DELAY_MS shl (attempt - 1)
                    try {
                        Thread.sleep(backoff)
                    } catch (ignored: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                    waitForUsableUnderlyingNetwork(
                        validatedTimeoutMs = VALIDATED_NETWORK_WAIT_MS,
                        unvalidatedFallbackMs = UNVALIDATED_NETWORK_FALLBACK_MS,
                    )
                }
            }

            if (!succeeded) {
                Log.e(TAG, "Failed to start VPN after $START_MAX_ATTEMPTS attempts", lastError)
                try {
                    vpnCore?.stop()
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping VPN runtime after start failure", e)
                }
                cleanupTunnel()
                isRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                broadcastError(failedStartErrorMessage(lastError))
                stopSelf()
            }
        }
    }

    /**
     * Refines [describeTunnelHealth]'s `UpstreamDegraded` outcome with the
     * active underlying transport. When the user is on cellular AND the
     * upstream probe failed, the most likely cause is the carrier
     * SYN-dropping the configured node's IP — the exact scenario CDN
     * acceleration solves. Emit the connectivity failure-flavored message so the
     * Dart side raises the "需要 CDN 加速" guidance banner. On Wi-Fi
     * (which rarely filters VPS IPs), keep the original "switch nodes"
     * message — the carrier-block diagnosis would be misleading there.
     *
     * Healthy / DirectRouteDegraded / Unreachable outcomes pass through
     * unchanged.
     */
    private fun degradedOutcomeForCurrentTransport(
        health: TunnelHealth,
    ): TunnelHealthOutcome {
        val baseOutcome = describeTunnelHealth(health)
        if (health != TunnelHealth.UpstreamDegraded) {
            return baseOutcome
        }
        val onCellular =
            lastObservedUnderlyingNetworkType == INTERFACE_TYPE_CELLULAR
        if (!onCellular) {
            return baseOutcome
        }
        return TunnelHealthOutcome(
            notificationText =
                "VPN connected · carrier blocking node, enable CDN",
            statusMessage = cellularCarrierSynBlockMessage(),
        )
    }

    /**
     * Returns the error message to broadcast when every start attempt failed.
     * When the active underlying transport is cellular AND every probe came
     * back unreachable, the most likely cause is the carrier SYN-dropping
     * the configured node's IP — the exact scenario CDN acceleration
     * exists to solve. Surfacing a distinct, machine-readable string lets
     * the Dart side raise the "需要 CDN 加速" guidance banner without
     * keyword-matching free-form error text.
     */
    private fun failedStartErrorMessage(lastError: Throwable?): String {
        val originalMessage = lastError?.message ?: "Failed to start VPN"
        if (originalMessage != startupConnectivityFailureMessage()) {
            return originalMessage
        }
        val onCellular =
            lastObservedUnderlyingNetworkType == INTERFACE_TYPE_CELLULAR
        return if (onCellular) cellularCarrierSynBlockMessage() else originalMessage
    }

    private fun startupConnectivityFailureMessage(): String =
        "VPN tunnel started, but traffic could not reach public IP probe endpoints " +
            "through the selected node. The node may be unreachable or misconfigured."

    // Distinct from startupConnectivityFailureMessage so the Dart side can
    // string-match on it and surface the "carrier blocked, need CDN" banner.
    // See VpnProvider.cellularCarrierSynBlockMessage — both strings must
    // match exactly for the banner to fire.
    private fun cellularCarrierSynBlockMessage(): String =
        "Cellular carrier appears to be SYN-dropping the configured node's IP — " +
            "the tunnel started but no probe endpoint responded through it. " +
            "Enable CDN acceleration to route via a Cloudflare edge IP instead."

    private fun stopVpn() {
        stopHealthMonitor()
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
        if (restartInProgress) {
            Log.i(TAG, "Ignoring restart request because a restart is already in progress")
            return
        }
        restartInProgress = true

        thread(name = "PrivateDeploy-VPN-Restart") {
            val handleAtStart = lastObservedUnderlyingNetworkHandle
            val typeAtStart = lastObservedUnderlyingNetworkType
            var lastError: Throwable? = null
            var succeeded = false

            // Wait briefly for a VALIDATED underlying network. Android often
            // fires onAvailable() before the new transport has finished
            // validation, and core.restart() issued into that half-open window
            // tends to fail — which historically stopped the service and left
            // users stuck disconnected across Wi-Fi ↔ cellular switches.
            waitForUsableUnderlyingNetwork(
                validatedTimeoutMs = VALIDATED_NETWORK_WAIT_MS,
                unvalidatedFallbackMs = UNVALIDATED_NETWORK_FALLBACK_MS,
            )

            for (attempt in 1..RESTART_MAX_ATTEMPTS) {
                try {
                    startForeground(
                        NOTIFICATION_ID,
                        createNotification(
                            if (attempt == 1) "VPN is reconnecting"
                            else "VPN is reconnecting (retry $attempt)"
                        )
                    )
                    broadcastStatus("connecting", null)
                    val core = ensureVpnCore()
                    core.restart()
                    isRunning = true
                    captureCurrentUnderlyingNetworkSnapshot()

                    val health = checkTunnelHealth()
                    // Mirror startVpn's policy: don't retry on UpstreamDegraded.
                    // The same node from the same underlying network won't
                    // suddenly start passing offshore probes on a second
                    // attempt; only Unreachable (probe verifier hit no
                    // endpoints at all, possibly transient) earns a retry.
                    // Same regression guard as startVpn: cellular
                    // UpstreamDegraded must not be accepted, or tun0 ends up
                    // black-holing every offshore request on the device.
                    val onCellular = lastObservedUnderlyingNetworkType ==
                        INTERFACE_TYPE_CELLULAR
                    val acceptNow = when (health) {
                        TunnelHealth.Healthy,
                        TunnelHealth.DirectRouteDegraded -> true
                        TunnelHealth.UpstreamDegraded -> !onCellular
                        TunnelHealth.Unreachable -> false
                    }
                    if (acceptNow) {
                        val outcome = degradedOutcomeForCurrentTransport(health)
                        updateForegroundNotification(outcome.notificationText)
                        broadcastStatus("connected", outcome.statusMessage)
                        when (health) {
                            TunnelHealth.Healthy ->
                                Log.i(TAG, "VPN restarted successfully on attempt $attempt")
                            TunnelHealth.UpstreamDegraded ->
                                Log.w(
                                    TAG,
                                    "VPN restart attempt $attempt: tunnel up but upstream " +
                                        "unreachable; accepting degraded state. The new " +
                                        "underlying network probably can't reach the " +
                                        "configured node — user needs to switch nodes.",
                                )
                            TunnelHealth.DirectRouteDegraded ->
                                Log.w(
                                    TAG,
                                    "VPN restart attempt $attempt: upstream OK but direct " +
                                        "route still settling after handover; UI will show " +
                                        "stabilizing indicator until the periodic monitor " +
                                        "clears it.",
                                )
                            TunnelHealth.Unreachable -> Unit
                        }
                        succeeded = true
                        startHealthMonitor()
                        break
                    }

                    Log.w(
                        TAG,
                        "VPN restart attempt $attempt/$RESTART_MAX_ATTEMPTS: tunnel health=$health; " +
                            "retrying so a fresh upstream socket gets bound to the new " +
                            "underlying network",
                    )
                    lastError = IllegalStateException(
                        "Tunnel re-established but upstream verification failed",
                    )
                } catch (e: Throwable) {
                    lastError = e
                    Log.w(
                        TAG,
                        "VPN restart attempt $attempt/$RESTART_MAX_ATTEMPTS failed: ${e.message}",
                        e,
                    )
                }
                if (!succeeded && attempt < RESTART_MAX_ATTEMPTS) {
                    val backoff = RESTART_RETRY_BASE_DELAY_MS shl (attempt - 1)
                    try {
                        Thread.sleep(backoff)
                    } catch (ignored: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                    waitForUsableUnderlyingNetwork(
                        validatedTimeoutMs = VALIDATED_NETWORK_WAIT_MS,
                        unvalidatedFallbackMs = UNVALIDATED_NETWORK_FALLBACK_MS,
                    )
                }
            }

            restartInProgress = false

            if (!succeeded) {
                Log.e(TAG, "Failed to restart VPN after $RESTART_MAX_ATTEMPTS attempts", lastError)
                stopHealthMonitor()
                try {
                    vpnCore?.stop()
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping VPN runtime after restart failure", e)
                }
                cleanupTunnel()
                isRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                broadcastError(lastError?.message ?: "Failed to restart VPN")
                stopSelf()
                return@thread
            }

            // Flap detection: the underlying network might have changed again
            // while this restart was running. Compare the snapshot captured at
            // restart start against the one observed now; if they differ,
            // force another restart so we don't end up bound to whichever
            // network happened to be active mid-retry. Call restartVpn()
            // directly rather than scheduleUnderlyingNetworkRestartIfNeeded —
            // the latter compares against lastObserved* which was already
            // updated by the callback that ran during this restart, so it
            // would see "no change" and drop the request.
            val currentHandle = lastObservedUnderlyingNetworkHandle
            val currentType = lastObservedUnderlyingNetworkType
            if (currentHandle != handleAtStart || currentType != typeAtStart) {
                Log.i(
                    TAG,
                    "Underlying network changed during restart " +
                        "(${formatInterfaceType(typeAtStart)}@$handleAtStart -> " +
                        "${formatInterfaceType(currentType)}@$currentHandle); forcing follow-up restart",
                )
                mainHandler.postDelayed({ restartVpn() }, UNDERLYING_NETWORK_RESTART_DEBOUNCE_MS)
            }
        }
    }

    /**
     * Waits for an underlying transport that is good enough to ride.
     *
     * Strategy: prefer NET_CAPABILITY_VALIDATED (system has confirmed
     * Internet via captive-portal probe) up to [validatedTimeoutMs]. If the
     * carrier blocks Android's probe destinations entirely
     * (`connectivitycheck.gstatic.com` and friends — common on China
     * Mobile/Telecom/Unicom and on networks that aggressively filter
     * Google), VALIDATED never arrives but the network is in fact usable.
     * In that case, accept any INTERNET-capable, NOT_SUSPENDED transport
     * after [unvalidatedFallbackMs] so we don't deadlock until the longer
     * cap.
     */
    private fun waitForUsableUnderlyingNetwork(
        validatedTimeoutMs: Long,
        unvalidatedFallbackMs: Long,
    ) {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return
        val now = SystemClock.elapsedRealtime()
        val validatedDeadline = now + validatedTimeoutMs
        val unvalidatedDeadline = now + unvalidatedFallbackMs
        var loggedFallback = false

        while (SystemClock.elapsedRealtime() < validatedDeadline) {
            val network = findPreferredUnderlyingNetwork(connectivityManager)
            val capabilities = network?.let(connectivityManager::getNetworkCapabilities)
            if (capabilities != null) {
                val hasInternet =
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                val isValidated =
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                val notSuspended =
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
                if (hasInternet && isValidated) {
                    return
                }
                if (hasInternet && notSuspended &&
                    SystemClock.elapsedRealtime() >= unvalidatedDeadline
                ) {
                    if (!loggedFallback) {
                        Log.i(
                            TAG,
                            "Accepting unvalidated INTERNET-capable transport after " +
                                "${unvalidatedFallbackMs}ms; carrier may be blocking the " +
                                "captive-portal probe",
                        )
                        loggedFallback = true
                    }
                    return
                }
            }
            try {
                Thread.sleep(200)
            } catch (ignored: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
    }

    /**
     * Three-state health classification for the post-connect verifier.
     *
     * - [Healthy]: a "tunnel-required" endpoint (gstatic /generate_204)
     *   responded, which proves packets are exiting through the configured
     *   upstream node. The user can browse offshore sites normally.
     * - [UpstreamDegraded]: tunnel-required endpoints all failed, but a
     *   domestic-direct endpoint (baidu/qq) succeeded. tun0 is forwarding
     *   traffic and direct routing works, but the upstream VPS is unreachable
     *   from the current underlying network — typically because a Chinese
     *   carrier is blocking the node's IP after a Wi-Fi → cellular handover.
     *   The user is still partially functional but YouTube/Google won't work
     *   until they switch nodes.
     * - [Unreachable]: nothing responded. tun0 itself may be a black hole.
     */
    private enum class TunnelHealth {
        Healthy,
        UpstreamDegraded,
        DirectRouteDegraded,
        Unreachable,
    }

    /**
     * Probes the post-connect tunnel state. Verifies both routing classes the
     * tunnel must handle: the offshore proxy path (TUNNEL_REQUIRED) and the
     * domestic-direct path (REACHABILITY). Both must pass for Healthy — a
     * passing proxy path with a broken direct path (the 30-90 s settle window
     * after a Wi-Fi ↔ cellular handover) used to slip past as "Healthy" because
     * the verifier returned as soon as TUNNEL_REQUIRED succeeded, leaving the
     * UI green while baidu/qq tabs spun for another minute. We now keep the
     * cheaper fail-fast ordering (offshore first, since that's the failure mode
     * users hit most often) but also require one domestic-direct success before
     * declaring Healthy.
     */
    private fun checkTunnelHealth(): TunnelHealth {
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) ?: return TunnelHealth.Unreachable

        var lastUpstreamError: String? = null
        var lastUpstreamSource: String? = null
        var upstreamHealthy = true
        for (attempt in 1..EGRESS_VERIFY_UPSTREAM_REPEATS) {
            val result = NativeEgressProbe.probe(
                connectivityManager,
                endpoints = NativeEgressProbe.TUNNEL_REQUIRED_ENDPOINTS,
                timeoutMs = EGRESS_VERIFY_PROBE_TIMEOUT_MS,
                allowDomesticFallback = false,
            )
            if (!result.reachable) {
                lastUpstreamError = result.error
                upstreamHealthy = false
                Log.w(
                    TAG,
                    "Tunnel upstream probe $attempt/$EGRESS_VERIFY_UPSTREAM_REPEATS failed: " +
                        "${result.error}",
                )
                break
            }
            lastUpstreamSource = result.source
            Log.i(
                TAG,
                "Tunnel upstream probe $attempt/$EGRESS_VERIFY_UPSTREAM_REPEATS reachable via " +
                    "${result.source}",
            )
            if (attempt < EGRESS_VERIFY_UPSTREAM_REPEATS) {
                try {
                    Thread.sleep(EGRESS_VERIFY_UPSTREAM_REPEAT_DELAY_MS)
                } catch (ignored: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return TunnelHealth.Unreachable
                }
            }
        }

        // Always probe domestic-direct once. When upstream passed we still need
        // this to catch the post-handover settle window; when upstream failed
        // we still need this to distinguish "node blocked" from "tunnel dead".
        val domesticResult = NativeEgressProbe.probe(
            connectivityManager,
            endpoints = NativeEgressProbe.REACHABILITY_ENDPOINTS,
            timeoutMs = EGRESS_VERIFY_PROBE_TIMEOUT_MS,
            allowDomesticFallback = false,
        )

        if (upstreamHealthy && domesticResult.reachable) {
            Log.i(
                TAG,
                "Tunnel fully verified (upstream=$lastUpstreamSource, " +
                    "domestic=${domesticResult.source})",
            )
            return TunnelHealth.Healthy
        }

        if (upstreamHealthy && !domesticResult.reachable) {
            Log.w(
                TAG,
                "Tunnel upstream OK via $lastUpstreamSource but domestic-direct probe " +
                    "failed (${domesticResult.error}); direct route is still stabilising — " +
                    "common 30-90 s window right after a Wi-Fi ↔ cellular handover",
            )
            return TunnelHealth.DirectRouteDegraded
        }

        if (!upstreamHealthy && domesticResult.reachable) {
            Log.w(
                TAG,
                "Tunnel forwards domestic traffic via ${domesticResult.source} but upstream " +
                    "is unreachable ($lastUpstreamError); the configured node is likely " +
                    "blocked by the carrier or otherwise dead",
            )
            return TunnelHealth.UpstreamDegraded
        }

        Log.w(
            TAG,
            "Tunnel egress fully unreachable; upstream=$lastUpstreamError, " +
                "domestic=${domesticResult.error}",
        )
        return TunnelHealth.Unreachable
    }

    /**
     * Maps a [TunnelHealth] to the user-facing notification text and the
     * broadcast status message. Centralising this keeps startVpn() and
     * restartVpn() aligned on what each state means.
     */
    private data class TunnelHealthOutcome(
        val notificationText: String,
        val statusMessage: String?,
    )

    private fun describeTunnelHealth(health: TunnelHealth): TunnelHealthOutcome = when (health) {
        TunnelHealth.Healthy -> TunnelHealthOutcome(
            notificationText = "VPN connected",
            statusMessage = null,
        )
        TunnelHealth.UpstreamDegraded -> TunnelHealthOutcome(
            notificationText = "VPN connected · upstream blocked, switch nodes",
            statusMessage = "Tunnel is up, but this node's upstream can't be reached " +
                "from your current network. Try Wi-Fi or switching to a different node " +
                "— cellular carriers sometimes block VPS IPs.",
        )
        TunnelHealth.DirectRouteDegraded -> TunnelHealthOutcome(
            notificationText = "VPN connected · stabilizing direct routes",
            statusMessage = "Tunnel is up and the upstream node responds, but the " +
                "direct-route path (used for domestic sites) is still settling. " +
                "Some traffic may stall for up to a minute — common right after " +
                "switching between Wi-Fi and cellular.",
        )
        TunnelHealth.Unreachable -> TunnelHealthOutcome(
            notificationText = "VPN egress unreachable",
            statusMessage = "Tunnel is up but egress could not be verified. " +
                "Browsing may not work — try a different node or network.",
        )
    }

    private fun updateConfig(config: String) {
        if (config.isBlank()) {
            broadcastError("VPN config is empty")
            return
        }
        val runtimeConfig = try {
            prepareConfigForRuntime(config)
        } catch (e: Exception) {
            broadcastError("Invalid config: not valid JSON - ${e.message}")
            return
        }

        thread(name = "PrivateDeploy-VPN-UpdateConfig") {
            try {
                val core = ensureVpnCore()
                core.updateConfig(runtimeConfig)
                activeConfig = runtimeConfig
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
        installBundledRuleSets(File(runtimeRoot, "rulesets"))

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

    private fun prepareConfigForRuntime(config: String): String {
        val runtimeRoot = File(noBackupFilesDir ?: filesDir, "vpncore")
        val ruleSetDir = File(runtimeRoot, "rulesets")
        installBundledRuleSets(ruleSetDir)

        val json = JSONObject(config)
        val route = json.optJSONObject("route") ?: return config
        val ruleSets = route.optJSONArray("rule_set") ?: return config
        var changed = false

        for (index in 0 until ruleSets.length()) {
            val ruleSet = ruleSets.optJSONObject(index) ?: continue
            if (ruleSet.optString("type") != "local") {
                continue
            }
            val path = ruleSet.optString("path")
            if (path.isBlank() || File(path).isAbsolute) {
                continue
            }

            val target = File(ruleSetDir, File(path).name)
            if (!target.exists()) {
                continue
            }
            ruleSet.put("path", target.absolutePath)
            changed = true
        }

        return if (changed) json.toString() else config
    }

    private fun installBundledRuleSets(ruleSetDir: File) {
        try {
            ruleSetDir.mkdirs()
            val assetNames = assets.list("rulesets").orEmpty()
            for (assetName in assetNames) {
                if (!assetName.endsWith(".json")) {
                    continue
                }
                val target = File(ruleSetDir, assetName)
                assets.open("rulesets/$assetName").use { input ->
                    target.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to install bundled rule sets", e)
        }
    }

    private fun cleanupTunnel() {
        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close VPN interface", e)
        } finally {
            vpnInterface = null
            // Forget what we last published — the next establish() will need
            // to publish from scratch even if it lands on the same Network
            // handle as the previous session.
            lastPublishedUnderlyingNetworkHandle = null
            lastPublishedUnderlyingNetworkPublished = false
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

    /**
     * Refreshes the foreground service notification's content text without
     * tearing the FGS state down. Re-using startForeground() with the same
     * NOTIFICATION_ID is the documented way to update an FGS notification —
     * NotificationManager.notify() works too but doesn't re-anchor the FGS,
     * which matters on Android 14+ where reposting is also how you keep the
     * service exempt from background time limits.
     *
     * Reason this helper exists: previously the notification text was set
     * to "VPN is connecting" at startForeground() time and never updated
     * after the tunnel reached the connected state, so the persistent
     * notification lied about the connection state for the entire session.
     */
    private fun updateForegroundNotification(text: String) {
        startForeground(NOTIFICATION_ID, createNotification(text))
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
                "message" to if (isRunning) latestStatusMessage else null,
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

        // Layer the most recent broadcast message on top of libbox's
        // internal status so dart polling sees the dart-facing diagnostic
        // (e.g. "upstream blocked, switch nodes") rather than libbox's
        // empty/internal one. Clear when not connected so old warnings
        // don't bleed into a fresh disconnect/reconnect.
        if (parsedStatus["status"] == "connected") {
            val cached = latestStatusMessage
            if (!cached.isNullOrBlank()) {
                parsedStatus["message"] = cached
            }
        } else {
            parsedStatus["message"] = null
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
        // Cache the latest connected-state message so polling getStatus()
        // returns it; clear it on any non-connected transition so a stale
        // degraded warning doesn't survive into a fresh connect attempt.
        latestStatusMessage = if (status == "connected") message else null
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
        pendingUnderlyingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingUnderlyingNetworkRestart = null
        stopHealthMonitor()
        unregisterUnderlyingNetworkMonitor()
        if (serviceInstance === this) {
            serviceInstance = null
        }
        super.onDestroy()
        Log.d(TAG, "VPN Service destroyed")
    }

    // ─── Periodic post-connect health monitor ───────────────────────────────
    //
    // checkTunnelHealth() only ran once at startVpn/restartVpn success. After
    // a Wi-Fi ↔ cellular handover the upstream proxy path tends to recover
    // within a few seconds (urltest re-probes its members) but the
    // domestic-direct path can stay broken for 30-90 s while DHCP/routes
    // settle and sing-box's outbound dialers shake off stale TCP state.
    // During that window the UI used to show 已连接 (green) even though
    // baidu/qq/etc tabs spun. This monitor re-runs the same dual-path probe
    // on a slow cadence and broadcasts state transitions so the UI can drop
    // to a stabilizing/degraded indicator until both classes pass again.
    private val healthMonitorHandler = Handler(Looper.getMainLooper())
    private var healthMonitorRunnable: Runnable? = null
    @Volatile
    private var lastBroadcastTunnelHealth: TunnelHealth? = null

    private fun startHealthMonitor() {
        stopHealthMonitor()
        // Seed with whatever state the entry probe just produced so a clean
        // green-to-green stays a no-op broadcast.
        lastBroadcastTunnelHealth = TunnelHealth.Healthy
        val runnable = object : Runnable {
            override fun run() {
                if (!isRunning) {
                    return
                }
                if (restartInProgress) {
                    healthMonitorHandler.postDelayed(this, HEALTH_MONITOR_INTERVAL_MS)
                    return
                }
                thread(name = "PrivateDeploy-VPN-HealthCheck", isDaemon = true) {
                    val health = try {
                        checkTunnelHealth()
                    } catch (e: Throwable) {
                        Log.w(TAG, "Periodic health probe failed", e)
                        null
                    }
                    if (health != null && health != lastBroadcastTunnelHealth) {
                        Log.i(
                            TAG,
                            "Health monitor: $lastBroadcastTunnelHealth → $health",
                        )
                        val outcome = describeTunnelHealth(health)
                        // Stay in the "connected" status family — we don't
                        // want to flip the user back into a connecting/error
                        // banner just because a probe came back ambiguous.
                        // The statusMessage payload conveys the degraded
                        // sub-state to the Dart side.
                        broadcastStatus("connected", outcome.statusMessage)
                        updateForegroundNotification(outcome.notificationText)
                        lastBroadcastTunnelHealth = health
                    }
                }
                healthMonitorHandler.postDelayed(this, HEALTH_MONITOR_INTERVAL_MS)
            }
        }
        healthMonitorRunnable = runnable
        healthMonitorHandler.postDelayed(runnable, HEALTH_MONITOR_INTERVAL_MS)
        Log.i(TAG, "Started periodic health monitor (interval ${HEALTH_MONITOR_INTERVAL_MS}ms)")
    }

    private fun stopHealthMonitor() {
        healthMonitorRunnable?.let(healthMonitorHandler::removeCallbacks)
        healthMonitorRunnable = null
        lastBroadcastTunnelHealth = null
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

        builder.allowBypass()

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
        // Tell Android which physical transport is carrying our upstream
        // sockets. Without this, the framework keeps the VPN's underlying
        // network frozen at whatever was default when establish() was called,
        // so on Wi-Fi → cellular handover apps still see the VPN as riding
        // the dead Wi-Fi (NOT_VALIDATED, NOT_NOT_SUSPENDED), system DNS and
        // OkHttp/Volley default-network detection start refusing traffic, and
        // the user sees "connected" but nothing actually flows. sing-box's
        // own auto_detect_interface rebinds new outbound sockets to cellular
        // correctly — this call fixes the orthogonal problem at the Android
        // framework layer.
        publishUnderlyingNetwork("openTun")
        return established.fd
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        Log.d(TAG, "Protecting outbound socket fd=$fd")
        if (!protect(fd)) {
            Log.e(TAG, "Failed to protect outbound socket fd=$fd")
            throw IllegalStateException("Failed to protect socket fd=$fd")
        }
        Log.d(TAG, "Protected outbound socket fd=$fd")
    }

    override fun writeLog(message: String?) {
        if (message.isNullOrBlank()) {
            return
        }
        if (shouldMirrorRuntimeLogToLogcat(message)) {
            when (runtimeLogPriority(message)) {
                Log.ERROR -> Log.e(TAG, "[vpncore] $message")
                Log.WARN -> Log.w(TAG, "[vpncore] $message")
                Log.INFO -> Log.i(TAG, "[vpncore] $message")
                else -> Log.d(TAG, "[vpncore] $message")
            }
        }
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

    private fun registerUnderlyingNetworkMonitor() {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return
        if (underlyingNetworkCallback != null) {
            return
        }
        readCurrentUnderlyingNetworkSnapshot(connectivityManager)?.also { snapshot ->
            lastObservedUnderlyingNetworkHandle = snapshot.handle
            lastObservedUnderlyingNetworkType = snapshot.type
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                scheduleUnderlyingNetworkRestartIfNeeded("available")
            }

            override fun onLost(network: Network) {
                scheduleUnderlyingNetworkRestartIfNeeded("lost")
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                scheduleUnderlyingNetworkRestartIfNeeded("capabilities")
            }
        }
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            connectivityManager.registerNetworkCallback(request, callback)
            underlyingNetworkCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register underlying network monitor", e)
        }
    }

    private fun unregisterUnderlyingNetworkMonitor() {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = underlyingNetworkCallback ?: return
        try {
            connectivityManager.unregisterNetworkCallback(callback)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister underlying network monitor", e)
        } finally {
            underlyingNetworkCallback = null
        }
    }

    private fun scheduleUnderlyingNetworkRestartIfNeeded(reason: String) {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return
        val previousHandle = lastObservedUnderlyingNetworkHandle
        val previousType = lastObservedUnderlyingNetworkType
        val snapshot = readCurrentUnderlyingNetworkSnapshot(connectivityManager)
        if (snapshot == null) {
            // No underlying network currently available (typical mid-transition
            // between Wi-Fi and cellular). Mark the observed handle as absent so
            // the next onAvailable/capabilities callback is treated as a
            // change and triggers a restart. Do NOT early-return without this
            // flip, or a fast onLost→onAvailable sequence on the same Network
            // object can be silently ignored.
            if (lastObservedUnderlyingNetworkHandle != null) {
                Log.i(TAG, "Underlying network unavailable ($reason); waiting for next available network")
            }
            lastObservedUnderlyingNetworkHandle = null
            lastObservedUnderlyingNetworkType = null
            // Clear Android's underlying-network attribution so apps don't keep
            // seeing the VPN as backed by the dead transport during the gap.
            applyUnderlyingNetworks(null, "$reason/unavailable")
            return
        }
        if (previousHandle == snapshot.handle && previousType == snapshot.type) {
            return
        }

        lastObservedUnderlyingNetworkHandle = snapshot.handle
        lastObservedUnderlyingNetworkType = snapshot.type

        // Tell Android about the new transport immediately, before the
        // debounced restart kicks in. setUnderlyingNetworks is cheap and
        // independent of socket rebuild — restart() refreshes sing-box's
        // own outbound bindings, this call refreshes the framework's view
        // of which physical network the VPN is actually riding.
        publishUnderlyingNetwork("change/$reason", connectivityManager)

        // Gate on user-intent (activeConfig is set by startVpn() and never
        // cleared except on app process death), not on isRunning. Otherwise a
        // previous handover-restart that hit RESTART_MAX_ATTEMPTS leaves
        // isRunning = false and *every* subsequent NetworkCallback short-
        // circuits here, stranding the user on a dead tunnel that only a
        // manual reconnect can revive. The whole point of NetworkCallback-
        // driven restart is to *recover* from such failures.
        if (activeConfig.isNullOrBlank()) {
            return
        }

        val now = SystemClock.elapsedRealtime()
        val earliestRestartAt = lastUnderlyingRestartAtMs + MIN_UNDERLYING_NETWORK_RESTART_INTERVAL_MS
        val delay = maxOf(
            UNDERLYING_NETWORK_RESTART_DEBOUNCE_MS,
            earliestRestartAt - now,
            0L,
        )

        pendingUnderlyingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingUnderlyingNetworkRestart = Runnable {
            pendingUnderlyingNetworkRestart = null
            if (activeConfig.isNullOrBlank() || restartInProgress) {
                return@Runnable
            }
            lastUnderlyingRestartAtMs = SystemClock.elapsedRealtime()
            Log.i(
                TAG,
                "Underlying network changed ($reason): ${formatInterfaceType(previousType)}@$previousHandle -> ${formatInterfaceType(snapshot.type)}@${snapshot.handle}; restarting VPN to flush stale upstream sockets",
            )
            restartVpn()
        }
        mainHandler.postDelayed(pendingUnderlyingNetworkRestart!!, delay)
    }

    private fun captureCurrentUnderlyingNetworkSnapshot(
        connectivityManager: ConnectivityManager? = getSystemService(ConnectivityManager::class.java)
    ): UnderlyingNetworkSnapshot? {
        connectivityManager ?: return null
        val snapshot = readCurrentUnderlyingNetworkSnapshot(connectivityManager) ?: return null
        lastObservedUnderlyingNetworkHandle = snapshot.handle
        lastObservedUnderlyingNetworkType = snapshot.type
        return snapshot
    }

    /**
     * Pushes the currently preferred physical Network into Android's view of
     * the VPN via [VpnService.setUnderlyingNetworks]. Without this, the
     * framework keeps the VPN's underlying network frozen at whatever was
     * default at establish() time, which breaks the framework-level
     * "VPN-is-validated" signal across Wi-Fi ↔ cellular handovers.
     */
    private fun publishUnderlyingNetwork(
        reason: String,
        connectivityManager: ConnectivityManager? =
            getSystemService(ConnectivityManager::class.java),
    ) {
        connectivityManager ?: return
        val network = findPreferredUnderlyingNetwork(connectivityManager)
        applyUnderlyingNetworks(
            network?.let { arrayOf(it) },
            reason,
        )
    }

    private fun applyUnderlyingNetworks(networks: Array<Network>?, reason: String) {
        // Single-network publishes are the only shape we currently produce
        // (publishUnderlyingNetwork wraps findPreferredUnderlyingNetwork's
        // result in a 1-element array). Anything else falls through to a
        // forced publish so future multi-network use cases still work.
        val desiredHandle = networks?.singleOrNull()?.networkHandle
        val desiredPublished = networks != null
        val isSimpleShape = networks == null || networks.size == 1
        if (
            isSimpleShape &&
            desiredPublished == lastPublishedUnderlyingNetworkPublished &&
            desiredHandle == lastPublishedUnderlyingNetworkHandle
        ) {
            return
        }
        try {
            setUnderlyingNetworks(networks)
            lastPublishedUnderlyingNetworkPublished = desiredPublished
            lastPublishedUnderlyingNetworkHandle = desiredHandle
            if (networks == null) {
                Log.i(TAG, "Cleared underlying networks ($reason)")
            } else {
                Log.i(
                    TAG,
                    "Updated underlying networks ($reason): " +
                        networks.joinToString { it.networkHandle.toString() },
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to setUnderlyingNetworks ($reason)", e)
        }
    }

    private fun readCurrentUnderlyingNetworkSnapshot(
        connectivityManager: ConnectivityManager,
    ): UnderlyingNetworkSnapshot? {
        val network = findPreferredUnderlyingNetwork(connectivityManager) ?: return null
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return null
        val linkProperties = connectivityManager.getLinkProperties(network) ?: return null
        val interfaceName = linkProperties.interfaceName?.trim().orEmpty()
        if (interfaceName.isEmpty()) {
            return null
        }
        return UnderlyingNetworkSnapshot(
            handle = network.networkHandle,
            type = determineNetworkType(capabilities),
            interfaceName = interfaceName,
            interfaceIndex = runCatching { NetworkInterface.getByName(interfaceName)?.index ?: 0 }
                .getOrDefault(0),
            expensive = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            constrained = Build.VERSION.SDK_INT >= 36 &&
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED),
        )
    }

    private fun determineNetworkType(capabilities: NetworkCapabilities): Int {
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> INTERFACE_TYPE_WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> INTERFACE_TYPE_CELLULAR
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> INTERFACE_TYPE_ETHERNET
            else -> INTERFACE_TYPE_OTHER
        }
    }

    private fun formatInterfaceType(type: Int?): String {
        return when (type) {
            INTERFACE_TYPE_WIFI -> "wifi"
            INTERFACE_TYPE_CELLULAR -> "cellular"
            INTERFACE_TYPE_ETHERNET -> "ethernet"
            INTERFACE_TYPE_OTHER -> "other"
            else -> "unknown"
        }
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

    private data class UnderlyingNetworkSnapshot(
        val handle: Long,
        val type: Int,
        val interfaceName: String,
        val interfaceIndex: Int,
        val expensive: Boolean,
        val constrained: Boolean,
    )

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
