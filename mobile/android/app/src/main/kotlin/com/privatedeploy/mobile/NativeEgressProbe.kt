package com.privatedeploy.mobile

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
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

    // A common desktop-browser UA. The old "PrivateDeploy/1.0" was exactly the
    // kind of automation UA that IP-echo services rate-limit / 403, which made
    // the egress verdict flap even while the tunnel forwarded fine.
    private const val PROBE_USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    // Provider-diverse IP-echo endpoints. The previous list was four
    // Cloudflare/US-fronted services (ipify/api64.ipify/ifconfig.me/icanhazip),
    // so a single provider block or CN-edge hijack took out ALL of them at once
    // and the tunnel was declared dead even though it carried traffic. Spreading
    // across AWS (checkip.amazonaws.com), ipinfo, ident.me, etc. means a probe
    // failure now reflects the tunnel, not one CDN's throttling policy.
    val DEFAULT_ENDPOINTS: List<EgressProbeEndpoint> = listOf(
        EgressProbeEndpoint("https://checkip.amazonaws.com"),
        EgressProbeEndpoint("https://api.ipify.org?format=json"),
        EgressProbeEndpoint("https://ipinfo.io/ip"),
        EgressProbeEndpoint("https://ifconfig.me/ip"),
        EgressProbeEndpoint("https://ident.me"),
        EgressProbeEndpoint("https://icanhazip.com"),
    )

    // Pure reachability endpoints: any HTTP success here proves the tunnel is
    // forwarding traffic, even if no public IP can be extracted. Used as a
    // fallback for the dart-facing probe (when DEFAULT_ENDPOINTS all fail
    // from the current network). NOT sufficient for the post-connect
    // verifier on its own — these endpoints are matched by sing-box's
    // "国内直连" routing rules and fall back to direct outbound, so they stay
    // reachable even when the configured upstream node is completely dead
    // (e.g. the current network cannot reach the VPS IP). Pair with TUNNEL_REQUIRED_ENDPOINTS
    // to distinguish "tun0 forwards traffic" from "the chosen node actually
    // works".
    val REACHABILITY_ENDPOINTS: List<EgressProbeEndpoint> = listOf(
        EgressProbeEndpoint("https://www.baidu.com/favicon.ico"),
        EgressProbeEndpoint("https://www.qq.com/favicon.ico"),
    )

    // Endpoints that only answer when packets genuinely exit through the
    // configured upstream node (foreign hosts sing-box routes via the proxy,
    // NOT matched by the "国内直连" rules). Reachability here means the tunnel
    // forwards offshore traffic. We deliberately do NOT require a parsed IP:
    // an HTTP response of ANY status (200 or 403/429) proves the bytes
    // round-tripped through tun0 → outbound → the real host and back, which is
    // the only thing the health verdict actually needs. Requiring an IP body
    // is what let a group-403 (all endpoints throttling our automation UA)
    // masquerade as a dead tunnel. The list is provider-diverse for the same
    // reason as DEFAULT_ENDPOINTS.
    val TUNNEL_REQUIRED_ENDPOINTS: List<EgressProbeEndpoint> = DEFAULT_ENDPOINTS

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
        requireVpnNetwork: Boolean = false,
    ): EgressProbeResult {
        var lastError: String? = null
        var reachableSource: String? = null

        for (endpoint in endpoints) {
            try {
                val response = fetchProbeResponse(
                    connectivityManager,
                    endpoint,
                    timeoutMs,
                    requireVpnNetwork,
                )
                val ip = extractIpFromProbePayload(response.body)
                if (!ip.isNullOrBlank()) {
                    Log.i(TAG, "VPN egress probe succeeded via ${endpoint.url} -> $ip")
                    return EgressProbeResult(ip = ip, source = endpoint.url, reachable = true)
                }
                // An HTTP response of ANY status came back through the bound
                // (VPN) network. That alone proves tun0 → outbound → the real
                // host round-tripped, i.e. the tunnel forwards offshore traffic
                // — even a 403/429 means the packet reached the far end and it
                // answered. Only a connection-level failure (caught below) means
                // "no forwarding". Keep iterating in case a later endpoint also
                // yields a display IP, but record reachability now.
                if (reachableSource == null) {
                    reachableSource = endpoint.url
                }
                Log.i(
                    TAG,
                    "VPN egress probe reachable via ${endpoint.url} " +
                        "(status ${response.statusCode}, no public IP)",
                )
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
                    val response = fetchProbeResponse(
                        connectivityManager,
                        endpoint,
                        timeoutMs,
                        requireVpnNetwork,
                    )
                    Log.i(
                        TAG,
                        "VPN egress probe reachable via ${endpoint.url} " +
                            "(status ${response.statusCode}, no public IP)",
                    )
                    return EgressProbeResult(source = endpoint.url, reachable = true)
                } catch (error: Exception) {
                    Log.w(TAG, "VPN egress reachability fallback failed for ${endpoint.url}", error)
                }
            }
        }

        return EgressProbeResult(error = lastError ?: "Unable to determine current egress IP.")
    }

    fun waitForVpnNetwork(
        connectivityManager: ConnectivityManager,
        timeoutMs: Long,
        pollMs: Long = 100L,
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            if (findPreferredProbeNetwork(
                    connectivityManager,
                    requireVpnNetwork = true,
                ) != null
            ) {
                return true
            }
            val remainingMs = deadline - SystemClock.elapsedRealtime()
            if (remainingMs <= 0L) {
                return false
            }
            try {
                Thread.sleep(if (remainingMs < pollMs) remainingMs else pollMs)
            } catch (ignored: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
    }

    private data class ProbeHttpResponse(val statusCode: Int, val body: String)

    /**
     * Issues the probe GET and returns the HTTP status plus body. Crucially it
     * does NOT throw on 4xx/5xx: a status line of any kind means the request
     * traversed the bound network end-to-end (the far host answered), which is
     * the reachability signal the health verdict needs. Only genuine
     * connection-level failures (DNS, connect timeout, TLS reset, no route)
     * propagate as exceptions — those are the real "tunnel doesn't forward".
     */
    private fun fetchProbeResponse(
        connectivityManager: ConnectivityManager?,
        endpoint: EgressProbeEndpoint,
        timeoutMs: Int,
        requireVpnNetwork: Boolean,
    ): ProbeHttpResponse {
        val url = URL(endpoint.url)
        val connection = openProbeConnection(connectivityManager, url, requireVpnNetwork)
        try {
            connection.instanceFollowRedirects = true
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json, text/plain;q=0.9, */*;q=0.8")
            connection.setRequestProperty("User-Agent", PROBE_USER_AGENT)
            endpoint.hostHeader?.let { connection.setRequestProperty("Host", it) }
            connection.connect()

            // responseCode itself throws if the connection never produced an
            // HTTP response (timeout/reset/etc.) — that surfaces as "not
            // reachable" to the caller, which is correct.
            val statusCode = connection.responseCode

            // Only a 2xx body can carry a usable egress IP; 204/no-body and
            // 4xx/5xx still count as reachable (handled by the caller) but we
            // must read errorStream (not inputStream) for >=400 to avoid an
            // IOException, and we don't need that body at all.
            val body = if (statusCode in 200..299 &&
                statusCode != 204 &&
                connection.contentLength != 0
            ) {
                try {
                    connection.inputStream.bufferedReader().use { it.readText() }
                } catch (_: Exception) {
                    ""
                }
            } else {
                ""
            }
            return ProbeHttpResponse(statusCode, body)
        } finally {
            connection.disconnect()
        }
    }

    private fun openProbeConnection(
        connectivityManager: ConnectivityManager?,
        url: URL,
        requireVpnNetwork: Boolean,
    ): HttpURLConnection {
        val preferredNetwork = connectivityManager?.let {
            findPreferredProbeNetwork(it, requireVpnNetwork)
        }
        if (requireVpnNetwork && preferredNetwork == null) {
            throw IllegalStateException("VPN network is not visible to ConnectivityManager yet")
        }
        if (connectivityManager != null) {
            Log.d(
                TAG,
                "VPN egress probe using " +
                    describeProbeNetwork(connectivityManager, preferredNetwork) +
                    " for ${url.host}",
            )
        }
        val connection = preferredNetwork?.openConnection(url) ?: url.openConnection()
        return connection as? HttpURLConnection
            ?: throw IllegalStateException("Unsupported probe connection type for $url")
    }

    /**
     * Picks the network the probe should ride. VPN transport is heavily
     * preferred (so a probe issued while the tunnel is up flows through
     * the tunnel), then validation, then transport quality.
     */
    private fun findPreferredProbeNetwork(
        connectivityManager: ConnectivityManager,
        requireVpnNetwork: Boolean = false,
    ): Network? {
        val activeNetwork = connectivityManager.activeNetwork
        var bestNetwork: Network? = null
        var bestScore = Int.MIN_VALUE

        connectivityManager.allNetworks.forEach { network ->
            val capabilities =
                connectivityManager.getNetworkCapabilities(network) ?: return@forEach
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return@forEach
            }
            val isVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            if (requireVpnNetwork && !isVpn) {
                return@forEach
            }
            var score = 0
            if (isVpn) {
                score += 5000
            }
            if (network == activeNetwork) {
                score += 100
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

    private fun describeProbeNetwork(
        connectivityManager: ConnectivityManager,
        network: Network?,
    ): String {
        if (network == null) {
            return "system-default"
        }
        val capabilities = connectivityManager.getNetworkCapabilities(network)
            ?: return "network@${network.networkHandle}"
        val transports = mutableListOf<String>()
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            transports.add("vpn")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            transports.add("cellular")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            transports.add("wifi")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            transports.add("ethernet")
        }
        if (transports.isEmpty()) {
            transports.add("other")
        }
        val flags = mutableListOf<String>()
        if (network == connectivityManager.activeNetwork) {
            flags.add("active")
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
            flags.add("validated")
        }
        return "${transports.joinToString("+")}@${network.networkHandle}" +
            if (flags.isEmpty()) "" else "(${flags.joinToString(",")})"
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
