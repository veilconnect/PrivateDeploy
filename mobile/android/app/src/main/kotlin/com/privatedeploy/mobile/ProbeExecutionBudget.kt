package com.privatedeploy.mobile

import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

/**
 * Hard wall-clock budget for the one-shot health gate used by start/restart.
 *
 * [HttpURLConnection.connectTimeout] and readTimeout do not cover every part
 * of Android name resolution through a VPN. A single DNS request can therefore
 * sit inside netd/sing-box for roughly 30 seconds before the first endpoint is
 * even dialled. Running the blocking sweep behind this deadline keeps the
 * native start result comfortably below VpnPlugin's 90-second timeout.
 */
internal object StartupHealthProbePolicy {
    const val TOTAL_BUDGET_MS = 25_000L
    const val DOMESTIC_RESERVE_MS = 5_000L
}

private val probeBudgetThreadSequence = AtomicLong(0)

/**
 * Runs [task] on a daemon worker and returns [onTimeout] once [budgetMs]
 * expires. Cancellation interrupts the worker; NativeEgressProbe checks that
 * flag between endpoints so a connection that ignores interruption cannot go
 * on to start the rest of the six-endpoint sweep after it finally unwinds.
 */
internal fun <T> runWithinExecutionBudget(
    budgetMs: Long,
    onTimeout: () -> T,
    task: () -> T,
): T {
    if (budgetMs <= 0L) return onTimeout()

    val future = FutureTask(Callable { task() })
    Thread(
        future,
        "PrivateDeploy-ProbeBudget-${probeBudgetThreadSequence.incrementAndGet()}",
    ).apply {
        isDaemon = true
        start()
    }

    return try {
        future.get(budgetMs, TimeUnit.MILLISECONDS)
    } catch (_: TimeoutException) {
        future.cancel(true)
        onTimeout()
    } catch (_: InterruptedException) {
        future.cancel(true)
        Thread.currentThread().interrupt()
        onTimeout()
    } catch (error: ExecutionException) {
        val cause = error.cause ?: error
        when (cause) {
            is Error -> throw cause
            is RuntimeException -> throw cause
            else -> throw RuntimeException(cause)
        }
    }
}
