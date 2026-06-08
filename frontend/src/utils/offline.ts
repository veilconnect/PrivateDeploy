import { ref, watch } from 'vue'

import { logInfo, logWarn } from './logger'

// Online/offline状态
export const isOnline = ref(navigator.onLine)

// 离线数据缓存键
const OFFLINE_CACHE_KEYS = {
  nodes: 'offline-cache-nodes',
  config: 'offline-cache-config',
  regions: 'offline-cache-regions',
  plans: 'offline-cache-plans',
}

/**
 * Initialize offline detection
 */
export function initOfflineMode() {
  const handleOnline = () => {
    isOnline.value = true
    logInfo('[Offline] Back online')
  }

  const handleOffline = () => {
    isOnline.value = false
    logWarn('[Offline] Connection lost')
  }

  window.addEventListener('online', handleOnline)
  window.addEventListener('offline', handleOffline)

  // Return cleanup function
  return () => {
    window.removeEventListener('online', handleOnline)
    window.removeEventListener('offline', handleOffline)
  }
}

/**
 * Save data to offline cache
 */
export function saveToOfflineCache<T>(key: keyof typeof OFFLINE_CACHE_KEYS, data: T): void {
  try {
    const cacheKey = OFFLINE_CACHE_KEYS[key]
    const cacheData = {
      data,
      timestamp: Date.now(),
    }
    localStorage.setItem(cacheKey, JSON.stringify(cacheData))
    logInfo(`[Offline] Cached ${key} data`)
  } catch (error) {
    logWarn(`[Offline] Failed to cache ${key}`, error)
  }
}

/**
 * Load data from offline cache
 */
export function loadFromOfflineCache<T>(key: keyof typeof OFFLINE_CACHE_KEYS): T | null {
  try {
    const cacheKey = OFFLINE_CACHE_KEYS[key]
    const cached = localStorage.getItem(cacheKey)

    if (!cached) {
      return null
    }

    const cacheData = JSON.parse(cached)
    logInfo(`[Offline] Loaded ${key} from cache (age: ${Date.now() - cacheData.timestamp}ms)`)

    return cacheData.data as T
  } catch (error) {
    logWarn(`[Offline] Failed to load ${key} from cache`, error)
    return null
  }
}

/**
 * Clear offline cache
 */
export function clearOfflineCache(key?: keyof typeof OFFLINE_CACHE_KEYS): void {
  if (key) {
    localStorage.removeItem(OFFLINE_CACHE_KEYS[key])
    logInfo(`[Offline] Cleared ${key} cache`)
  } else {
    Object.values(OFFLINE_CACHE_KEYS).forEach(cacheKey => {
      localStorage.removeItem(cacheKey)
    })
    logInfo('[Offline] Cleared all offline cache')
  }
}

/**
 * Get cache age in milliseconds
 */
export function getCacheAge(key: keyof typeof OFFLINE_CACHE_KEYS): number | null {
  try {
    const cacheKey = OFFLINE_CACHE_KEYS[key]
    const cached = localStorage.getItem(cacheKey)

    if (!cached) {
      return null
    }

    const cacheData = JSON.parse(cached)
    return Date.now() - cacheData.timestamp
  } catch {
    return null
  }
}

/**
 * Check if offline cache exists
 */
export function hasOfflineCache(key: keyof typeof OFFLINE_CACHE_KEYS): boolean {
  return localStorage.getItem(OFFLINE_CACHE_KEYS[key]) !== null
}

/**
 * Sync pending operations when back online
 */
const pendingOperations: Array<() => Promise<void>> = []

export function queueOfflineOperation(operation: () => Promise<void>): void {
  pendingOperations.push(operation)
  logInfo(`[Offline] Queued operation (total: ${pendingOperations.length})`)
}

export async function syncPendingOperations(): Promise<void> {
  if (!isOnline.value || pendingOperations.length === 0) {
    return
  }

  logInfo(`[Offline] Syncing ${pendingOperations.length} pending operations`)

  while (pendingOperations.length > 0) {
    const operation = pendingOperations.shift()
    if (operation) {
      try {
        await operation()
      } catch (error) {
        logWarn('[Offline] Failed to sync operation', error)
        // Re-queue failed operation
        pendingOperations.unshift(operation)
        break
      }
    }
  }

  if (pendingOperations.length === 0) {
    logInfo('[Offline] All operations synced successfully')
  } else {
    logWarn(`[Offline] ${pendingOperations.length} operations still pending`)
  }
}

// Auto-sync when back online
watch(isOnline, (online) => {
  if (online) {
    setTimeout(() => {
      syncPendingOperations()
    }, 1000) // Wait 1s after reconnect
  }
})
