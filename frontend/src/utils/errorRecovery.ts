import { logError, logInfo } from './logger'

export interface RetryOptions {
  maxAttempts?: number
  baseDelay?: number
  maxDelay?: number
  exponentialBackoff?: boolean
  shouldRetry?: (error: any, attempt: number) => boolean
}

const defaultOptions: Required<RetryOptions> = {
  maxAttempts: 3,
  baseDelay: 1000, // 1 second
  maxDelay: 30000, // 30 seconds
  exponentialBackoff: true,
  shouldRetry: () => true,
}

/**
 * Retry a function with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  operationName: string,
  options: RetryOptions = {}
): Promise<T> {
  const opts = { ...defaultOptions, ...options }
  let lastError: any

  for (let attempt = 1; attempt <= opts.maxAttempts; attempt++) {
    try {
      logInfo(`[Retry] Attempt ${attempt}/${opts.maxAttempts} for ${operationName}`)
      const result = await fn()
      if (attempt > 1) {
        logInfo(`[Retry] ${operationName} succeeded after ${attempt} attempts`)
      }
      return result
    } catch (error) {
      lastError = error

      // Check if we should retry
      if (!opts.shouldRetry(error, attempt)) {
        logError(`[Retry] ${operationName} failed, not retrying`, error)
        throw error
      }

      // Don't retry if this was the last attempt
      if (attempt === opts.maxAttempts) {
        break
      }

      // Calculate delay with exponential backoff
      let delay = opts.baseDelay
      if (opts.exponentialBackoff) {
        delay = Math.min(opts.baseDelay * Math.pow(2, attempt - 1), opts.maxDelay)
      }

      logInfo(`[Retry] ${operationName} failed, retrying in ${delay}ms (attempt ${attempt}/${opts.maxAttempts})`, error)
      await sleep(delay)
    }
  }

  logError(`[Retry] ${operationName} failed after ${opts.maxAttempts} attempts`, lastError)
  throw lastError
}

/**
 * Check if error is a network error
 */
export function isNetworkError(error: any): boolean {
  const errorString = String(error).toLowerCase()
  return (
    errorString.includes('network') ||
    errorString.includes('timeout') ||
    errorString.includes('connection') ||
    errorString.includes('fetch') ||
    errorString.includes('econnrefused')
  )
}

/**
 * Check if error is a rate limit error
 */
export function isRateLimitError(error: any): boolean {
  const errorString = String(error).toLowerCase()
  return (
    errorString.includes('rate limit') ||
    errorString.includes('429') ||
    errorString.includes('too many requests')
  )
}

/**
 * Check if error is an auth error
 */
export function isAuthError(error: any): boolean {
  const errorString = String(error).toLowerCase()
  return (
    errorString.includes('unauthorized') ||
    errorString.includes('401') ||
    errorString.includes('403') ||
    errorString.includes('forbidden') ||
    errorString.includes('invalid api key') ||
    errorString.includes('authentication')
  )
}

/**
 * Default retry strategy for API calls
 */
export const apiRetryStrategy = {
  shouldRetry: (error: any, attempt: number): boolean => {
    // Don't retry auth errors
    if (isAuthError(error)) {
      return false
    }

    // Always retry network errors
    if (isNetworkError(error)) {
      return true
    }

    // Retry rate limit errors with longer delay
    if (isRateLimitError(error)) {
      return attempt < 3
    }

    // Retry other errors up to 2 attempts
    return attempt < 2
  },
  maxAttempts: 3,
  baseDelay: 2000,
  exponentialBackoff: true,
}

/**
 * Sleep utility
 */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Retry queue for failed operations
 */
class RetryQueue {
  private queue: Array<{
    id: string
    fn: () => Promise<any>
    options: RetryOptions
    createdAt: number
  }> = []

  add(id: string, fn: () => Promise<any>, options: RetryOptions = {}) {
    this.queue.push({
      id,
      fn,
      options,
      createdAt: Date.now(),
    })
  }

  async processAll(): Promise<void> {
    const items = [...this.queue]
    this.queue = []

    for (const item of items) {
      try {
        await retryWithBackoff(item.fn, item.id, item.options)
      } catch (error) {
        logError(`[RetryQueue] Failed to process ${item.id}`, error)
      }
    }
  }

  clear() {
    this.queue = []
  }

  get length() {
    return this.queue.length
  }
}

export const retryQueue = new RetryQueue()
