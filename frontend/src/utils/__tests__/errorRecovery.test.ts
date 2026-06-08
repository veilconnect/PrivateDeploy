import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../logger', () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}))

import {
  apiRetryStrategy,
  isAuthError,
  isNetworkError,
  isRateLimitError,
  retryQueue,
  retryWithBackoff,
} from '../errorRecovery'

describe('error recovery utilities', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    retryQueue.clear()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    retryQueue.clear()
  })

  it('retries with exponential backoff until an operation succeeds', async () => {
    const operation = vi
      .fn()
      .mockRejectedValueOnce(new Error('network timeout'))
      .mockResolvedValueOnce('ok')

    const task = retryWithBackoff(operation, 'test-op', {
      maxAttempts: 3,
      baseDelay: 100,
    })
    await vi.advanceTimersByTimeAsync(100)

    await expect(task).resolves.toBe('ok')
    expect(operation).toHaveBeenCalledTimes(2)
  })

  it('stops immediately when shouldRetry rejects the error', async () => {
    const operation = vi.fn().mockRejectedValue(new Error('unauthorized'))

    await expect(
      retryWithBackoff(operation, 'auth-op', {
        shouldRetry: () => false,
      }),
    ).rejects.toThrow('unauthorized')
    expect(operation).toHaveBeenCalledTimes(1)
  })

  it('classifies retryable error types for API strategy', () => {
    expect(isNetworkError('ECONNREFUSED')).toBe(true)
    expect(isRateLimitError('429 too many requests')).toBe(true)
    expect(isAuthError('invalid api key')).toBe(true)

    expect(apiRetryStrategy.shouldRetry('401 unauthorized', 1)).toBe(false)
    expect(apiRetryStrategy.shouldRetry('network timeout', 3)).toBe(true)
    expect(apiRetryStrategy.shouldRetry('429 too many requests', 2)).toBe(true)
    expect(apiRetryStrategy.shouldRetry('server exploded', 2)).toBe(false)
  })

  it('processes queued retry tasks and clears successful entries', async () => {
    const first = vi.fn().mockResolvedValue('done')
    const second = vi.fn().mockResolvedValue('done')
    retryQueue.add('first', first, { baseDelay: 1 })
    retryQueue.add('second', second, { baseDelay: 1 })

    await retryQueue.processAll()

    expect(first).toHaveBeenCalledTimes(1)
    expect(second).toHaveBeenCalledTimes(1)
    expect(retryQueue.length).toBe(0)
  })
})
