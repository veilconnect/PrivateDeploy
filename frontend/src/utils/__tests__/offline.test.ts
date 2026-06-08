import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../logger', () => ({
  logInfo: vi.fn(),
  logWarn: vi.fn(),
}))

import {
  clearOfflineCache,
  getCacheAge,
  hasOfflineCache,
  initOfflineMode,
  isOnline,
  loadFromOfflineCache,
  queueOfflineOperation,
  saveToOfflineCache,
  syncPendingOperations,
} from '../offline'

describe('offline utilities', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    localStorage.clear()
    isOnline.value = true
  })

  afterEach(async () => {
    isOnline.value = true
    await syncPendingOperations()
    vi.useRealTimers()
    vi.restoreAllMocks()
    localStorage.clear()
  })

  it('saves, loads, ages, and clears offline cache entries', () => {
    saveToOfflineCache('nodes', [{ id: 'node-1' }])

    expect(hasOfflineCache('nodes')).toBe(true)
    expect(loadFromOfflineCache('nodes')).toEqual([{ id: 'node-1' }])

    vi.mocked(Date.now).mockReturnValue(1_700_000_002_500)
    expect(getCacheAge('nodes')).toBe(2_500)

    clearOfflineCache('nodes')
    expect(hasOfflineCache('nodes')).toBe(false)

    saveToOfflineCache('regions', ['nrt'])
    saveToOfflineCache('plans', ['vc2'])
    clearOfflineCache()
    expect(hasOfflineCache('regions')).toBe(false)
    expect(hasOfflineCache('plans')).toBe(false)
  })

  it('returns null for missing or malformed cache entries', () => {
    expect(loadFromOfflineCache('config')).toBeNull()

    localStorage.setItem('offline-cache-config', 'not-json')
    expect(loadFromOfflineCache('config')).toBeNull()
    expect(getCacheAge('config')).toBeNull()
  })

  it('tracks browser online and offline events with cleanup', () => {
    const cleanup = initOfflineMode()

    window.dispatchEvent(new Event('offline'))
    expect(isOnline.value).toBe(false)

    window.dispatchEvent(new Event('online'))
    expect(isOnline.value).toBe(true)

    cleanup()
    window.dispatchEvent(new Event('offline'))
    expect(isOnline.value).toBe(true)
  })

  it('syncs queued operations only while online and preserves failed work', async () => {
    const failed = vi.fn().mockRejectedValueOnce(new Error('still offline')).mockResolvedValueOnce(undefined)
    const successful = vi.fn().mockResolvedValue(undefined)
    queueOfflineOperation(failed)
    queueOfflineOperation(successful)

    isOnline.value = false
    await syncPendingOperations()
    expect(failed).not.toHaveBeenCalled()

    isOnline.value = true
    await syncPendingOperations()
    expect(failed).toHaveBeenCalledTimes(1)
    expect(successful).not.toHaveBeenCalled()

    await syncPendingOperations()
    expect(failed).toHaveBeenCalledTimes(2)
    expect(successful).toHaveBeenCalledTimes(1)
  })
})
