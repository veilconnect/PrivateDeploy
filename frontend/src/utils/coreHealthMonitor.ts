import { useKernelApiStore } from '@/stores'

type CleanupFn = () => void

const POLL_INTERVAL_MS = 30_000
const TRIGGER_THROTTLE_MS = 2_000

let setupDone = false

// Watches for drift between the app's view of the sing-box core and the real OS process.
// Recovers from: core crash, laptop sleep/wake, OS network transitions, alt-tab suspension.
// The current on-boot updateCoreState() only fires once; this keeps it honest across the
// app's lifetime by polling and reacting to window/document events.
export const setupCoreHealthMonitor = (): CleanupFn => {
  if (setupDone) return () => undefined
  setupDone = true

  const kernelApiStore = useKernelApiStore()
  let lastTriggerAt = 0

  const trigger = (reason: string) => {
    const now = Date.now()
    if (now - lastTriggerAt < TRIGGER_THROTTLE_MS) return
    lastTriggerAt = now

    kernelApiStore.checkCoreHealth().catch((error) => {
      console.error(`[CoreHealth] check (${reason}) failed:`, error)
    })
  }

  const intervalId = window.setInterval(() => trigger('poll'), POLL_INTERVAL_MS)

  const onOnline = () => trigger('online')
  const onVisibility = () => {
    if (!document.hidden) trigger('visibility')
  }
  const onFocus = () => trigger('focus')

  window.addEventListener('online', onOnline)
  document.addEventListener('visibilitychange', onVisibility)
  window.addEventListener('focus', onFocus)

  return () => {
    window.clearInterval(intervalId)
    window.removeEventListener('online', onOnline)
    document.removeEventListener('visibilitychange', onVisibility)
    window.removeEventListener('focus', onFocus)
    setupDone = false
  }
}
