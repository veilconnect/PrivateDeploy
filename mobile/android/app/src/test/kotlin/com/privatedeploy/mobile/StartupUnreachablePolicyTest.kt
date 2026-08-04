package com.privatedeploy.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupUnreachablePolicyTest {
    @Test
    fun `validated cellular unreachable fails without another start attempt`() {
        assertTrue(
            StartupUnreachablePolicy.shouldFailFast(
                isCellular = true,
                isValidated = true,
                isSameNetwork = true,
            ),
        )
    }

    @Test
    fun `unvalidated cellular unreachable retains transient retry`() {
        assertFalse(
            StartupUnreachablePolicy.shouldFailFast(
                isCellular = true,
                isValidated = false,
                isSameNetwork = true,
            ),
        )
    }

    @Test
    fun `validated wifi unreachable does not use cellular fail-fast`() {
        assertFalse(
            StartupUnreachablePolicy.shouldFailFast(
                isCellular = false,
                isValidated = true,
                isSameNetwork = true,
            ),
        )
    }

    @Test
    fun `validated cellular handover retains transient retry`() {
        assertFalse(
            StartupUnreachablePolicy.shouldFailFast(
                isCellular = true,
                isValidated = true,
                isSameNetwork = false,
            ),
        )
    }
}
