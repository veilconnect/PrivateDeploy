import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/stores', () => ({
  useKernelApiStore: vi.fn(),
}))

import { useKernelApiStore } from '@/stores'

import { setupCoreHealthMonitor } from '../coreHealthMonitor'

const useKernelApiStoreMock = vi.mocked(useKernelApiStore)

describe('core health monitor', () => {
  let cleanup = () => undefined
  let checkCoreHealth: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
    vi.clearAllMocks()
    checkCoreHealth = vi.fn().mockResolvedValue(undefined)
    useKernelApiStoreMock.mockReturnValue({ checkCoreHealth } as any)
    Object.defineProperty(document, 'hidden', { configurable: true, value: false })
  })

  afterEach(() => {
    cleanup()
    cleanup = () => undefined
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('polls core health and throttles rapid event triggers', () => {
    cleanup = setupCoreHealthMonitor()

    vi.advanceTimersByTime(30_000)
    expect(checkCoreHealth).toHaveBeenCalledTimes(1)

    window.dispatchEvent(new Event('online'))
    expect(checkCoreHealth).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(2_000)
    window.dispatchEvent(new Event('online'))
    expect(checkCoreHealth).toHaveBeenCalledTimes(2)

    Object.defineProperty(document, 'hidden', { configurable: true, value: true })
    vi.advanceTimersByTime(2_000)
    document.dispatchEvent(new Event('visibilitychange'))
    expect(checkCoreHealth).toHaveBeenCalledTimes(2)

    Object.defineProperty(document, 'hidden', { configurable: true, value: false })
    document.dispatchEvent(new Event('visibilitychange'))
    expect(checkCoreHealth).toHaveBeenCalledTimes(3)

    vi.advanceTimersByTime(2_000)
    window.dispatchEvent(new Event('focus'))
    expect(checkCoreHealth).toHaveBeenCalledTimes(4)
  })

  it('keeps setup singleton until cleanup runs', () => {
    cleanup = setupCoreHealthMonitor()
    const secondCleanup = setupCoreHealthMonitor()

    expect(useKernelApiStoreMock).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(30_000)
    expect(checkCoreHealth).toHaveBeenCalledTimes(1)

    secondCleanup()
    vi.advanceTimersByTime(30_000)
    expect(checkCoreHealth).toHaveBeenCalledTimes(2)

    cleanup()
    cleanup = () => undefined
    vi.advanceTimersByTime(30_000)
    expect(checkCoreHealth).toHaveBeenCalledTimes(2)
  })

  it('logs failed health checks without throwing from the monitor', async () => {
    const error = new Error('boom')
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})
    checkCoreHealth.mockRejectedValueOnce(error)

    cleanup = setupCoreHealthMonitor()
    vi.advanceTimersByTime(30_000)
    await Promise.resolve()
    await Promise.resolve()

    expect(consoleError).toHaveBeenCalledWith('[CoreHealth] check (poll) failed:', error)
  })
})
