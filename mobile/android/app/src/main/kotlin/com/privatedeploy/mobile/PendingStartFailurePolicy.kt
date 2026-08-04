package com.privatedeploy.mobile

/**
 * Decides whether VpnPlugin must issue ACTION_STOP after a pending start fails.
 *
 * A terminal service-owned failure tears down the core and owns the stopSelf()
 * lifecycle. Sending another asynchronous STOP from the plugin can arrive
 * after Dart has already started a backup node, cancelling that new start
 * instead of the failed one.
 */
internal object PendingStartFailurePolicy {
    fun shouldSendStop(
        pendingStartDispatched: Boolean,
        serviceOwnsShutdown: Boolean,
    ): Boolean = pendingStartDispatched && !serviceOwnsShutdown
}
