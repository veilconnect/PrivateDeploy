package com.privatedeploy.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingStartFailurePolicyTest {
    @Test
    fun `service-owned terminal error does not enqueue stale stop`() {
        assertFalse(
            PendingStartFailurePolicy.shouldSendStop(
                pendingStartDispatched = true,
                serviceOwnsShutdown = true,
            ),
        )
    }

    @Test
    fun `plugin-owned failure still cleans up dispatched start`() {
        assertTrue(
            PendingStartFailurePolicy.shouldSendStop(
                pendingStartDispatched = true,
                serviceOwnsShutdown = false,
            ),
        )
    }

    @Test
    fun `undispatched failure never sends stop`() {
        assertFalse(
            PendingStartFailurePolicy.shouldSendStop(
                pendingStartDispatched = false,
                serviceOwnsShutdown = false,
            ),
        )
    }
}
