package com.privatedeploy.mobile

/** The kind of Android [android.net.Network] selected for an HTTP probe. */
internal enum class ProbeNetworkKind {
    NONE,
    VPN,
    NON_VPN,
    UNKNOWN,
}

/**
 * Decides whether a probe should use [android.net.Network.openConnection].
 *
 * A socket that should traverse the app's own VPN must remain unbound: Android
 * routes an ordinary, unprotected app socket into the VPN, while explicitly
 * binding that socket back to the VPN Network can fail with EPERM on Android
 * 17. A known physical Network may still be bound explicitly for diagnostics
 * that do not require the VPN.
 */
internal object ProbeNetworkBindingPolicy {
    fun shouldBindExplicitly(
        networkKind: ProbeNetworkKind,
        requireVpnNetwork: Boolean,
    ): Boolean = !requireVpnNetwork && networkKind == ProbeNetworkKind.NON_VPN
}
