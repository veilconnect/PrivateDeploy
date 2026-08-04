package com.privatedeploy.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbeNetworkBindingPolicyTest {
    @Test
    fun `vpn probe remains unbound when vpn is required`() {
        assertFalse(
            ProbeNetworkBindingPolicy.shouldBindExplicitly(
                networkKind = ProbeNetworkKind.VPN,
                requireVpnNetwork = true,
            ),
        )
    }

    @Test
    fun `optional probe also leaves a selected vpn unbound`() {
        assertFalse(
            ProbeNetworkBindingPolicy.shouldBindExplicitly(
                networkKind = ProbeNetworkKind.VPN,
                requireVpnNetwork = false,
            ),
        )
    }

    @Test
    fun `optional probe keeps explicit binding for a known physical network`() {
        assertTrue(
            ProbeNetworkBindingPolicy.shouldBindExplicitly(
                networkKind = ProbeNetworkKind.NON_VPN,
                requireVpnNetwork = false,
            ),
        )
    }

    @Test
    fun `vpn-required probe never binds a physical network`() {
        assertFalse(
            ProbeNetworkBindingPolicy.shouldBindExplicitly(
                networkKind = ProbeNetworkKind.NON_VPN,
                requireVpnNetwork = true,
            ),
        )
    }

    @Test
    fun `missing or stale network falls back to system routing`() {
        for (kind in listOf(ProbeNetworkKind.NONE, ProbeNetworkKind.UNKNOWN)) {
            assertFalse(
                ProbeNetworkBindingPolicy.shouldBindExplicitly(
                    networkKind = kind,
                    requireVpnNetwork = false,
                ),
            )
        }
    }
}
