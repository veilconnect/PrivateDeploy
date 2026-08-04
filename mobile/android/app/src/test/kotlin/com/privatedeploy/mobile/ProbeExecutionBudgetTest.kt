package com.privatedeploy.mobile

import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbeExecutionBudgetTest {
    @Test
    fun `returns completed task result within budget`() {
        val result = runWithinExecutionBudget(
            budgetMs = 1_000L,
            onTimeout = { "timeout" },
        ) {
            "complete"
        }

        assertEquals("complete", result)
    }

    @Test
    fun `hard deadline returns and interrupts blocked worker`() {
        val workerStarted = CountDownLatch(1)
        val workerInterrupted = CountDownLatch(1)
        val startedAt = System.nanoTime()

        val result = runWithinExecutionBudget(
            budgetMs = 50L,
            onTimeout = { "timeout" },
        ) {
            workerStarted.countDown()
            try {
                Thread.sleep(5_000L)
                "late"
            } catch (_: InterruptedException) {
                workerInterrupted.countDown()
                "interrupted"
            }
        }

        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
        assertEquals("timeout", result)
        assertEquals(0L, workerStarted.count)
        assertTrue("deadline should return well before the blocked task", elapsedMs < 1_000L)
        assertTrue(
            "timed-out worker should receive cancellation interrupt",
            workerInterrupted.await(1, TimeUnit.SECONDS),
        )
    }

    @Test
    fun `startup plan is bounded and starts without DNS`() {
        assertEquals(25_000L, StartupHealthProbePolicy.TOTAL_BUDGET_MS)
        assertTrue(
            StartupHealthProbePolicy.DOMESTIC_RESERVE_MS <
                StartupHealthProbePolicy.TOTAL_BUDGET_MS,
        )
        assertTrue(NativeEgressProbe.STARTUP_TUNNEL_REQUIRED_ENDPOINTS.size <= 3)

        val firstHosts = NativeEgressProbe.STARTUP_TUNNEL_REQUIRED_ENDPOINTS
            .take(2)
            .map { URL(it.url).host }
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), firstHosts)
    }
}
