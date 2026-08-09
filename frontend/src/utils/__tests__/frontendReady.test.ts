import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  markApplicationReady,
  markApplicationReadyAndRunBackgroundTask,
  signalFrontendReadyAfterMount,
} from '../frontendReady'

afterEach(() => {
  document.body.replaceChildren()
})

const makeVisible = (...elements: HTMLElement[]) => {
  for (const element of elements) {
    element.getBoundingClientRect = () =>
      ({
        x: 0,
        y: 0,
        top: 0,
        right: 640,
        bottom: 480,
        left: 0,
        width: 640,
        height: 480,
        toJSON: () => ({}),
      }) as DOMRect
  }
}

describe('signalFrontendReadyAfterMount', () => {
  it('signals only after startup renders the real application shell', async () => {
    const root = document.createElement('div')
    root.id = 'app'
    const shell = document.createElement('main')
    shell.dataset.applicationShell = 'true'
    const route = document.createElement('section')
    route.dataset.routeViewReady = 'true'
    const routeContent = document.createElement('div')
    route.append(routeContent)
    shell.append(route)
    root.append(shell)
    document.body.append(root)
    makeVisible(root, shell, routeContent)
    const signal = vi.fn(async () => undefined)
    const waitForRouter = vi.fn(async () => undefined)
    const waitForFrame = vi.fn(async () => undefined)

    const pending = signalFrontendReadyAfterMount(signal, undefined, waitForRouter, waitForFrame)
    await Promise.resolve()
    expect(signal).not.toHaveBeenCalled()

    markApplicationReady()
    await pending

    expect(signal).toHaveBeenCalledOnce()
    expect(waitForRouter).toHaveBeenCalledOnce()
    expect(waitForFrame).toHaveBeenCalledTimes(2)
    expect(root.dataset.frontendReady).toBe('true')
  })

  it('rejects a ready marker without a rendered application shell', async () => {
    const root = document.createElement('div')
    root.id = 'app'
    document.body.append(root)
    const signal = vi.fn(async () => undefined)

    markApplicationReady()

    await expect(signalFrontendReadyAfterMount(signal)).rejects.toThrow(
      'Vue did not render a ready application shell',
    )
    expect(signal).not.toHaveBeenCalled()
  })

  it('does not signal while the initial router navigation is unresolved', async () => {
    const root = document.createElement('div')
    root.id = 'app'
    root.dataset.applicationReady = 'true'
    const shell = document.createElement('main')
    shell.dataset.applicationShell = 'true'
    const route = document.createElement('section')
    route.dataset.routeViewReady = 'true'
    const routeContent = document.createElement('div')
    route.append(routeContent)
    shell.append(route)
    root.append(shell)
    document.body.append(root)
    makeVisible(root, shell, routeContent)

    let resolveRouter!: () => void
    const waitForRouter = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveRouter = resolve
        }),
    )
    const waitForFrame = vi.fn(async () => undefined)
    const signal = vi.fn(async () => undefined)

    const pending = signalFrontendReadyAfterMount(signal, undefined, waitForRouter, waitForFrame)
    await vi.waitFor(() => expect(waitForRouter).toHaveBeenCalledOnce())
    expect(signal).not.toHaveBeenCalled()

    resolveRouter()
    await pending

    expect(waitForFrame).toHaveBeenCalledTimes(2)
    expect(signal).toHaveBeenCalledOnce()
  })

  it('rejects an application shell whose RouterView has no rendered component', async () => {
    const root = document.createElement('div')
    root.id = 'app'
    root.dataset.applicationReady = 'true'
    const shell = document.createElement('main')
    shell.dataset.applicationShell = 'true'
    const route = document.createElement('section')
    route.dataset.routeViewReady = 'true'
    shell.append(route)
    root.append(shell)
    document.body.append(root)
    makeVisible(root, shell)
    const signal = vi.fn(async () => undefined)

    await expect(
      signalFrontendReadyAfterMount(
        signal,
        undefined,
        async () => undefined,
        async () => undefined,
      ),
    ).rejects.toThrow('Vue router did not render a visible ready route view')
    expect(signal).not.toHaveBeenCalled()
  })

  it('rejects a routed component that has no visible layout box', async () => {
    const root = document.createElement('div')
    root.id = 'app'
    root.dataset.applicationReady = 'true'
    const shell = document.createElement('main')
    shell.dataset.applicationShell = 'true'
    const route = document.createElement('section')
    route.dataset.routeViewReady = 'true'
    const routeContent = document.createElement('div')
    route.append(routeContent)
    shell.append(route)
    root.append(shell)
    document.body.append(root)
    makeVisible(root, shell)
    const signal = vi.fn(async () => undefined)

    await expect(
      signalFrontendReadyAfterMount(
        signal,
        undefined,
        async () => undefined,
        async () => undefined,
      ),
    ).rejects.toThrow('Vue router did not render a visible ready route view')
    expect(signal).not.toHaveBeenCalled()
  })

  it('rejects a detached root without signaling Go', async () => {
    const root = document.createElement('div')
    const shell = document.createElement('main')
    shell.dataset.applicationShell = 'true'
    root.append(shell)
    root.dataset.applicationReady = 'true'
    const signal = vi.fn(async () => undefined)

    await expect(signalFrontendReadyAfterMount(signal, () => root)).rejects.toThrow(
      'Vue did not render a ready application shell',
    )
    expect(signal).not.toHaveBeenCalled()
  })
})

describe('markApplicationReadyAndRunBackgroundTask', () => {
  it('publishes readiness without waiting for a never-settling startup plugin task', async () => {
    const markReady = vi.fn()
    const reportError = vi.fn()
    const neverSettles = vi.fn(() => new Promise<void>(() => undefined))

    markApplicationReadyAndRunBackgroundTask(neverSettles, reportError, markReady)

    expect(markReady).toHaveBeenCalledOnce()
    await vi.waitFor(() => expect(neverSettles).toHaveBeenCalledOnce())
    expect(reportError).not.toHaveBeenCalled()
  })

  it('consumes background failures and reports them once', async () => {
    const failure = new Error('plugin startup failed')
    const reportError = vi.fn()

    markApplicationReadyAndRunBackgroundTask(
      async () => Promise.reject(failure),
      reportError,
      vi.fn(),
    )

    await vi.waitFor(() => expect(reportError).toHaveBeenCalledWith(failure))
  })
})
