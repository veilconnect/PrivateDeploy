package com.privatedeploy.mobile

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import android.util.Patterns
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

internal data class EgressProbeEndpoint(
    val url: String,
    val hostHeader: String? = null,
)

internal data class EgressProbeResult(
    val ip: String? = null,
    val source: String? = null,
    val error: String? = null,
    // True when at least one probe HTTP request completed end-to-end. The IP
    // may still be unknown (e.g. a Chinese-friendly endpoint that doesn't
    // expose the egress IP), but the tunnel is provably forwarding traffic.
    val reachable: Boolean = false,
) {
    val hasIp: Boolean get() = !ip.isNullOrBlank()
}

/**
 * Shared HTTP egress probe used by both the Flutter-facing VpnPlugin
 * (for diagnostics surface) and PrivateDeployVpnService (for post-start
 * tunnel verification). Picks the highest-scoring INTERNET-capable
 * Network — preferring the active VPN transport — so the request is
 * routed through the tunnel when one is up.
 */
internal object NativeEgressProbe {
    private const val TAG = "EgressProbe"
    const val DEFAULT_TIMEOUT_MS: Int = 1500

    val DEFAULT_ENDPOINTS: List<EgressProbeEndpoint> = listOf(
        EgressProbeEndpoint("https://api.ipify.org?format=json"),
        EgressProbeEndpoint("https://api64.ipify.org?format=json"),
        EgressProbeEndpoint("https://ifconfig.me/ip"),
        EgressProbeEndpoint("https://icanhazip.com"),
    )

    // Pure reachability endpoints: any HTTP success here proves the tunnel is
    // forwarding traffic, even if no public IP can be extracted. Used as a
    // fallback for the dart-facing probe (when DEFAULT_ENDPOINTS all fail
    // due to Cloudflare blocking from CN). NOT sufficient for the post-connect
    // verifier on its own — these endpoints are matched by sing-box's
    // "国内直连" routing rules and fall back to direct outbound, so they stay
    // reachable even when the configured upstream node is completely dead
    // (e.g. carrier blocked the VPS IP). Pair with TUNNEL_REQUIRED_ENDPOINTS
    // to distinguish "tun0 forwards traffic" from "the chosen node actually
    // works".
    val REACHABILITY_ENDPOINTS: List<EgressProbeEndpoint> = listOf(
        EgressProbeEndpoint("https://www.baidu.com/favicon.ico"),
        EgressProbeEndpoint("https://www.qq.com/favicon.ico"),
    )

    // Endpoints that should only work when packets genuinely exit through the
    // configured upstream node. These must return a public IP, not merely a
    // 204/no-body reachability response: in the wild, Google's generate_204
    // can occasionally complete while the configured VPS socket is still
    // timing out, which made the service mark a broken tunnel Healthy. Keeping
    // this list IP-bearing aligns the startup health decision with the
    // Flutter diagnostics card and avoids a green "connected" state when the
    // app still cannot confirm egress.
    val TUNNEL_REQUIRED_ENDPOINTS: List<EgressProbeEndpoint> = listOf(
        EgressProbeEndpoint("https://api.ipify.org?format=json"),
        EgressProbeEndpoint("https://api64.ipify.org?format=json"),
        EgressProbeEndpoint("https://ifconfig.me/ip"),
        EgressProbeEndpoint("https://icanhazip.com"),
    )

    /**
     * @param allowDomesticFallback If true (default), and every [endpoints]
     *   request fails, retry against [REACHABILITY_ENDPOINTS] before giving
     *   up — convenient for the dart-facing diagnostics surface that just
     *   wants any reachability signal. Callers that need to attribute
     *   reachability to *the specific endpoint list they passed* (e.g. the
     *   service's three-state health probe distinguishing offshore-only
     *   endpoints from domestic-direct ones) MUST pass false, otherwise the
     *   fallback silently turns a TUNNEL_REQUIRED-only call into a
     *   REACHABILITY_ENDPOINTS call when the upstream is dead.
     */
    fun probe(
        connectivityManager: ConnectivityManager?,
        endpoints: List<EgressProbeEndpoint> = DEFAULT_ENDPOINTS,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
        allowDomesticFallback: Boolean = true,
    ): EgressProbeResult {
        var lastError: String? = null
        var reachableSource: String? = null

        for (endpoint in endpoints) {
            try {
                val payload = fetchProbePayload(connectivityManager, endpoint, timeoutMs)
                val ip = extractIpFromProbePayload(payload)
                if (!ip.isNullOrBlank()) {
                    Log.i(TAG, "VPN egress probe succeeded via ${endpoint.url} -> $ip")
                    return EgressProbeResult(ip = ip, source = endpoint.url, reachable = true)
                }
                // HTTP request completed end-to-end but the body didn't expose
                // an IP (e.g. a binary favicon). That still proves the tunnel
                // forwards traffic — keep iterating in case a later endpoint
                // does yield an IP, but record reachability so we can return
                // it if no IP ever materialises.
                if (reachableSource == null) {
                    reachableSource = endpoint.url
                }
                Log.i(TAG, "VPN egress probe reachable via ${endpoint.url} (no public IP)")
            } catch (timeout: SocketTimeoutException) {
                Log.w(TAG, "VPN egress probe timed out for ${endpoint.url}", timeout)
                lastError = "Timed out contacting public IP probe endpoints."
            } catch (error: Exception) {
                Log.w(TAG, "VPN egress probe failed for ${endpoint.url}", error)
                lastError = "Could not reach public IP probe endpoints through the current VPN route."
            }
        }

        if (reachableSource != null) {
            return EgressProbeResult(source = reachableSource, reachable = true)
        }

        // No endpoint completed an HTTP request — the primary list might be
        // entirely Cloudflare-fronted and blocked from CN. Try the
        // CN-friendly reachability list as a last resort, but skip if the
        // caller already passed it (avoids double-iterating the same URLs)
        // or asked us not to fall back (e.g. a tunnel-required-only health
        // probe that must NOT be satisfied by domestic-direct success).
        if (allowDomesticFallback && endpoints !== REACHABILITY_ENDPOINTS) {
            for (endpoint in REACHABILITY_ENDPOINTS) {
                try {
                    fetchProbePayload(connectivityManager, endpoint, timeoutMs)
                    Log.i(TAG, "VPN egress probe reachable via ${endpoint.url} (no public IP)")
                    return EgressProbeResult(source = endpoint.url, reachable = true)
                } catch (error: Exception) {
                    Log.w(TAG, "VPN egress reachability fallback failed for ${endpoint.url}", error)
                }
            }
        }

        return EgressProbeResult(error = lastError ?: "Unable to determine current egress IP.")
    }

    private fun fetchProbePayload(
        connectivityManager: ConnectivityManager?,
        endpoint: EgressProbeEndpoint,
        timeoutMs: Int,
    ): String {
        val url = URL(endpoint.url)
        val connection = openProbeConnection(connectivityManager, url)
        try {
            connection.instanceFollowRedirects = true
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json, text/plain;q=0.9, */*;q=0.8")
            connection.setRequestProperty("User-Agent", "PrivateDeploy/1.0")
            endpoint.hostHeader?.let { connection.setRequestProperty("Host", it) }
            connection.connect()

            val statusCode = connection.responseCode
            if (statusCode !in 200..399) {
                throw IllegalStateException("Unexpected HTTP status $statusCode from ${endpoint.url}")
            }

            // 204 No Content endpoints (e.g. /generate_204) intentionally have
            // no response body and HttpURLConnection returns a null inputStream
            // for them. Reaching this point means the request completed
            // end-to-end, which is all the reachability probe needs.
            if (statusCode == 204 || connection.contentLength == 0) {
                return ""
            }

            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun openProbeConnection(
        connectivityManager: ConnectivityManager?,
        url: URL,
    ): HttpURLConnection {
        val preferredNetwork = connectivityManager?.let(::findPreferredProbeNetwork)
        val connection = preferredNetwork?.openConnection(url) ?: url.openConnection()
        return connection as? HttpURLConnection
            ?: throw IllegalStateException("Unsupported probe connection type for $url")
    }

    /**
     * Picks the network the probe should ride. VPN transport is heavily
     * preferred (so a probe issued while the tunnel is up flows through
     * the tunnel), then validation, then transport quality.
     */
    private fun findPreferredProbeNetwork(connectivityManager: ConnectivityManager): Network? {
        val activeNetwork = connectivityManager.activeNetwork
        var bestNetwork: Network? = null
        var bestScore = Int.MIN_VALUE

        connectivityManager.allNetworks.forEach { network ->
            val capabilities =
                connectivityManager.getNetworkCapabilities(network) ?: return@forEach
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return@forEach
            }
            var score = 0
            if (network == activeNetwork) {
                score += 1000
            }
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                score += 500
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
