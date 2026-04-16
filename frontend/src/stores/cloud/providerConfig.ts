/**
 * Cloud Store - Provider Configuration
 *
 * Handles provider management, config loading/saving, and
 * fetching regions/plans/availability data.
 */


import {
  GetCloudConfig,
  SaveCloudConfig,
  ListCloudProviders,
  GetCloudProvider,
  SetCloudProvider,
  ListCloudRegions,
  ListCloudPlans,
  ListCloudAvailability,
} from '@/bridge'
import { deepClone } from '@/utils'
import { retryWithBackoff } from '@/utils/errorRecovery'
import { logError, logInfo } from '@/utils/logger'
import { notifications } from '@/utils/notification'
import { isOnline, saveToOfflineCache, loadFromOfflineCache } from '@/utils/offline'

import { CACHE_TTL } from './constants'

import type { CloudProvider, CloudConfig, CloudRegion, CloudPlan } from '@/types/cloud'
import type { Ref, ShallowRef } from 'vue'

export type ProviderConfigDeps = {
  availableProviders: Ref<Array<{ name: string; displayName: string }>>
  currentProvider: Ref<CloudProvider>
  config: CloudConfig
  configLoaded: Ref<boolean>
  savingConfig: Ref<boolean>
  regions: ShallowRef<CloudRegion[]>
  plans: ShallowRef<CloudPlan[]>
  availability: Record<string, string[]>
  loadingRegions: Ref<boolean>
  loadingPlans: Ref<boolean>
  regionsUpdatedAt: Ref<number | null>
  plansUpdatedAt: Ref<number | null>
  instances: ShallowRef<any[]>
  instancesUpdatedAt: Ref<number | null>
  startAutoRefresh: (refreshImmediately?: boolean) => void
  stopAutoRefresh: () => void
  refreshInstances: (silent?: boolean, force?: boolean) => Promise<void>
}

export function createProviderConfig(deps: ProviderConfigDeps) {
  const {
    availableProviders,
    currentProvider,
    config,
    configLoaded,
    savingConfig,
    regions,
    plans,
    availability,
    loadingRegions,
    loadingPlans,
    regionsUpdatedAt,
    plansUpdatedAt,
    instances,
    instancesUpdatedAt,
    startAutoRefresh,
    stopAutoRefresh,
    refreshInstances,
  } = deps

  /**
   * Check if cache is still valid
   */
  const isCacheValid = (timestamp: number | null, ttl: number): boolean => {
    if (!timestamp) return false
    return Date.now() - timestamp < ttl
  }

  const isRegionsCacheValid = () => isCacheValid(regionsUpdatedAt.value, CACHE_TTL.regions)
  const isPlansCacheValid = () => isCacheValid(plansUpdatedAt.value, CACHE_TTL.plans)

  const loadConfig = async () => {
    const loadedConfig = await GetCloudConfig()
    Object.assign(config, loadedConfig)
    config.provider = loadedConfig.provider ?? currentProvider.value
    config.extra = loadedConfig.extra ?? {}
    logInfo('[CloudStore] Loaded config, apiKey length:', config.apiKey?.length || 0)
    configLoaded.value = true
    if (config.apiKey && config.apiKey.trim() !== '') {
      startAutoRefresh(true)
    } else {
      stopAutoRefresh()
    }
  }

  const saveConfig = async () => {
    savingConfig.value = true
    try {
      // Align with backend's active provider to avoid "provider mismatch" when
      // the frontend's currentProvider lags behind a concurrent SetCloudProvider.
      try {
        const active = await GetCloudProvider()
        if (active?.name) {
          currentProvider.value = active.name as CloudProvider
        }
      } catch (err) {
        logError('[CloudStore] saveConfig: failed to resync active provider', err)
      }
      const payload = deepClone(config) as CloudConfig
      payload.provider = currentProvider.value
      payload.extra = payload.extra ?? {}
      await retryWithBackoff(
        () => SaveCloudConfig(payload),
        'SaveCloudConfig',
        {
          maxAttempts: 3,
          baseDelay: 1000,
          shouldRetry: (err) => !String(err).toLowerCase().includes('provider mismatch'),
        }
      )
      if (payload.apiKey && payload.apiKey.trim() !== '') {
        startAutoRefresh(true)
      } else {
        stopAutoRefresh()
      }

      notifications.configSaved()
    } catch (error) {
      notifications.error('Configuration Save Failed', error instanceof Error ? error.message : String(error))
      throw error
    } finally {
      savingConfig.value = false
    }
  }

  const fetchRegions = async (force = false) => {
    if (!force && isRegionsCacheValid() && regions.value.length > 0) {
      logInfo('[CloudStore] Using cached regions data')
      return
    }

    if (!isOnline.value) {
      const cached = loadFromOfflineCache<CloudRegion[]>('regions')
      if (cached) {
        regions.value = cached
        regionsUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Loaded regions from offline cache')
        return
      }
    }

    loadingRegions.value = true
    try {
      regions.value = await retryWithBackoff(
        () => ListCloudRegions(),
        'ListCloudRegions',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      regionsUpdatedAt.value = Date.now()

      saveToOfflineCache('regions', regions.value)

      logInfo('[CloudStore] Regions fetched and cached')
    } catch (error) {
      const cached = loadFromOfflineCache<CloudRegion[]>('regions')
      if (cached) {
        regions.value = cached
        regionsUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Failed to fetch regions, using offline cache')
      } else {
        throw error
      }
    } finally {
      loadingRegions.value = false
    }
  }

  const fetchPlans = async (force = false) => {
    if (!force && isPlansCacheValid() && plans.value.length > 0) {
      logInfo('[CloudStore] Using cached plans data')
      return
    }

    if (!isOnline.value) {
      const cached = loadFromOfflineCache<CloudPlan[]>('plans')
      if (cached) {
        plans.value = cached
        plansUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Loaded plans from offline cache')
        return
      }
    }

    loadingPlans.value = true
    try {
      plans.value = await retryWithBackoff(
        () => ListCloudPlans(),
        'ListCloudPlans',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      plansUpdatedAt.value = Date.now()

      saveToOfflineCache('plans', plans.value)

      logInfo('[CloudStore] Plans fetched and cached')
    } catch (error) {
      const cached = loadFromOfflineCache<CloudPlan[]>('plans')
      if (cached) {
        plans.value = cached
        plansUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Failed to fetch plans, using offline cache')
      } else {
        throw error
      }
    } finally {
      loadingPlans.value = false
    }
  }

  const ensureRegionAvailability = async (region: string, force = false) => {
    if (!region) return [] as string[]
    if (!force && availability[region]) {
      return availability[region]
    }

    if (!config.apiKey || config.apiKey.trim() === '') {
      availability[region] = availability[region] || []
      return availability[region]
    }

    try {
      availability[region] = await ListCloudAvailability(region)
    } catch (error) {
      logError('[CloudStore] Failed to load availability:', error)
      availability[region] = availability[region] || []
      throw error
    }

    return availability[region]
  }

  const loadProviders = async () => {
    try {
      if (typeof ListCloudProviders !== 'function') {
        console.warn('[CloudStore] ListCloudProviders not available, using default')
        availableProviders.value = [{ name: 'vultr', displayName: 'Vultr' }]
        return
      }

      availableProviders.value = await ListCloudProviders()
      console.log('[CloudStore] Loaded providers:', availableProviders.value)
    } catch (error) {
      logError('[CloudStore] Failed to load providers:', error)
      availableProviders.value = [{ name: 'vultr', displayName: 'Vultr' }]
    }
  }

  const switchProvider = async (provider: CloudProvider) => {
    try {
      // Save current provider's API key before switching — but only if the
      // backend's active provider still matches our local currentProvider,
      // otherwise saveConfig would write the old key to a different slot.
      if (config.apiKey && currentProvider.value) {
        let activeName: string | undefined
        try {
          const active = await GetCloudProvider()
          activeName = active?.name
        } catch (err) {
          logError('[CloudStore] switchProvider: active provider lookup failed', err)
        }
        if (activeName === currentProvider.value) {
          await saveConfig()
        }
      }

      // Reset config while loading new provider to avoid using stale credentials
      Object.assign(config, {
        apiKey: '',
        defaultPlan: '',
        defaultRegion: '',
        provider: provider,
        extra: {},
      })
      stopAutoRefresh()

      if (typeof SetCloudProvider !== 'function') {
        console.warn('[CloudStore] SetCloudProvider not available')
        currentProvider.value = provider
        return
      }

      const current = await SetCloudProvider(provider)
      currentProvider.value = current.name as CloudProvider
      console.log('[CloudStore] Switched to provider:', current)

      // Clear provider-scoped display data (regions/plans/availability) but
      // PRESERVE instances across provider switches. Nodes that were already
      // loaded should remain visible until a verified delete (explicit destroy
      // or connection probe confirming the node is gone). refreshInstances()
      // will merge the new provider's list with retained in-use nodes.
      regions.value = []
      plans.value = []
      Object.keys(availability).forEach((key) => delete availability[key])

      // Reload config and data for new provider (will load saved API key)
      await loadConfig()
      console.log('[CloudStore] After loadConfig, defaultRegion:', config.defaultRegion, 'defaultPlan:', config.defaultPlan)

      // Clear provider-specific defaults since region/plan IDs are not portable across providers
      config.defaultRegion = ''
      config.defaultPlan = ''
      console.log('[CloudStore] Cleared defaults, defaultRegion:', config.defaultRegion, 'defaultPlan:', config.defaultPlan)

      // Force-refresh instances on provider switch: retained cross-provider
      // nodes in instances.value would otherwise satisfy the cache-hit guard
      // in refreshInstances() and the new provider's list would never load.
      if (provider === 'ssh') {
        await refreshInstances(true, true)
      } else if (config.apiKey) {
        await Promise.all([fetchRegions(), fetchPlans()])
        console.log('[CloudStore] After fetching, regions count:', regions.value.length, 'plans count:', plans.value.length)
        await refreshInstances(true, true)
      }
    } catch (error) {
      logError('[CloudStore] Failed to switch provider:', error)
      throw error
    }
  }

  const getCurrentProvider = async () => {
    try {
      if (typeof GetCloudProvider !== 'function') {
        console.warn('[CloudStore] GetCloudProvider not available, using default')
        return
      }

      const provider = await GetCloudProvider()
      currentProvider.value = provider.name as CloudProvider
      console.log('[CloudStore] Current provider:', provider)
    } catch (error) {
      logError('[CloudStore] Failed to get current provider:', error)
    }
  }

  return {
    loadConfig,
    saveConfig,
    fetchRegions,
    fetchPlans,
    ensureRegionAvailability,
    loadProviders,
    switchProvider,
    getCurrentProvider,
    isRegionsCacheValid,
    isPlansCacheValid,
  }
}
