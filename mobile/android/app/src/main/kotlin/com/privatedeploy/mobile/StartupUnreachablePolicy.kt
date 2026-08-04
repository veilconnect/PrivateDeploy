package com.privatedeploy.mobile

/**
 * Bounds a user-initiated start after an explicit no-egress verdict.
 *
 * A validated cellular network has already passed Android's Internet check,
 * so an Unreachable verdict from both the proxy and domestic VPN-bound probes
 * identifies the newly installed tunnel as the black hole. Repeating the same
 * start on the same carrier only extends the outage. An unvalidated cellular
 * network may still be attaching after a handover, so it retains the normal
 * retry path; Wi-Fi keeps its existing connected-degraded behaviour.
 */
internal object StartupUnreachablePolicy {
    fun shouldFailFast(
        isCellular: Boolean,
        isValidated: Boolean,
        isSameNetwork: Boolean,
    ): Boolean = isCellular && isValidated && isSameNetwork
}
