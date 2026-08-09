import { nextTick } from 'vue'

export type FrontendReadySignal = () => Promise<void>
export type RouterReadyWaiter = () => Promise<unknown>
export type PaintFrameWaiter = () => Promise<void>
export type StartupBackgroundTask = () => Promise<void>
export type StartupBackgroundErrorHandler = (error: unknown) => void
const applicationReadyEvent = 'privatedeploy:application-ready'

const waitForPaintFrame: PaintFrameWaiter = () =>
  new Promise<void>((resolve) => {
    if (typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(() => resolve())
      return
    }
    window.setTimeout(resolve, 0)
  })

export const markApplicationReady = (
  findRoot: () => HTMLElement | null = () => document.getElementById('app'),
): void => {
  const root = findRoot()
  if (!root?.isConnected) return
  root.dataset.applicationReady = 'true'
  window.dispatchEvent(new Event(applicationReadyEvent))
}

// Publish the real-shell readiness marker before starting optional plugin
// lifecycle work. The task is deliberately detached: a plugin may be slow,
// broken, or wait for user consent, but none of those cases may keep the
// workspace on its splash screen or block the installer's frontend handshake.
// Both task and reporter failures are consumed so this fire-and-forget boundary
// never produces an unhandled promise rejection.
export const markApplicationReadyAndRunBackgroundTask = (
  task: StartupBackgroundTask,
  reportError: StartupBackgroundErrorHandler,
  markReady: () => void = markApplicationReady,
): void => {
  markReady()
  void Promise.resolve()
    .then(task)
    .catch((error) => {
      try {
        reportError(error)
      } catch (reportErrorFailure) {
        console.error('[Startup] Background error reporter failed:', reportErrorFailure)
      }
    })
}

// Wails' OnDomReady and Vue mount only prove that the splash screen loaded.
// Wait until App.vue finishes its startup sequence and renders the real shell,
// otherwise an indefinitely stuck bootstrap would still pass installation.
export const signalFrontendReadyAfterMount = async (
  signal: FrontendReadySignal,
  findRoot: () => HTMLElement | null = () => document.getElementById('app'),
  waitForRouter: RouterReadyWaiter = async () => undefined,
  waitForFrame: PaintFrameWaiter = waitForPaintFrame,
): Promise<void> => {
  await nextTick()

  if (findRoot()?.dataset.applicationReady !== 'true') {
    await new Promise<void>((resolve) => {
      window.addEventListener(applicationReadyEvent, () => resolve(), { once: true })
    })
    await nextTick()
  }

  let root = findRoot()
  let shell = root?.querySelector<HTMLElement>('[data-application-shell="true"]')
  if (
    !root ||
    !root.isConnected ||
    root.dataset.applicationReady !== 'true' ||
    !shell?.isConnected
  ) {
    throw new Error('Vue did not render a ready application shell')
  }

  // The shell can exist while the initial router guard/lazy component is still
  // unresolved. Wait for router readiness and two animation frames so an empty
  // RouterView (or a renderer that never advances toward paint) cannot satisfy
  // the installer's frontend challenge.
  await waitForRouter()
  await nextTick()
  await waitForFrame()
  await waitForFrame()

  root = findRoot()
  shell = root?.querySelector<HTMLElement>('[data-application-shell="true"]')
  const routeView = shell?.querySelector<HTMLElement>('[data-route-view-ready="true"]')
  if (
    !root ||
    !root.isConnected ||
    root.dataset.applicationReady !== 'true' ||
    !shell?.isConnected ||
    !routeView?.isConnected ||
    routeView.childElementCount === 0
  ) {
    throw new Error('Vue router did not render a ready route view')
  }

  await signal()
  root.dataset.frontendReady = 'true'
}
