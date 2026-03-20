import { onMounted, onUnmounted, watch, type Ref } from 'vue'

import { message } from '@/utils'
import { logError } from '@/utils/logger'

import type { CloudProvider } from '@/types/cloud'
import type { RegionLatency } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type DeployFormState = {
  label: string
  region: string
  plan: string
}

type CloudStoreLike = {
  regions: Array<{ id: string }>
  plans: Array<{ id: string }>
  availability: Record<string, string[]>
  config: {
    apiKey: string
    defaultRegion?: string
    defaultPlan?: string
  }
  loadingInstances: boolean
  latencyTestResults: Record<string, number>
  latencyUpdatedAt: number | null
  currentProvider: CloudProvider
  isLatencyCacheValid: () => boolean
  ensureRegionAvailability: (region: string, force?: boolean) => Promise<string[]>
  fetchRegions: () => Promise<void>
  fetchPlans: () => Promise<void>
  refreshInstances: (silent?: boolean, force?: boolean) => Promise<void>
  loadProviders: () => Promise<void>
  getCurrentProvider: () => Promise<void>
  loadManualNodes: () => Promise<unknown>
  loadConfig: () => Promise<void>
  switchProvider: (provider: CloudProvider) => Promise<void>
  saveConfig: () => Promise<void>
  clearAllTimers: () => void
}

type TestAllCloudRegionsResult = {
  flag: boolean
  data: string
}

type UseCloudViewMetaDeps = {
  cloudStore: CloudStoreLike
  form: DeployFormState
  hasApiKey: Ref<boolean>
  testingLatency: Ref<boolean>
  latencyResults: Ref<RegionLatency[]>
  showLatencyResults: Ref<boolean>
  handleError: (error: unknown) => void
  translate: TranslateFn
  testAllCloudRegions: () => Promise<TestAllCloudRegionsResult>
}

export const defaultCloudLabel = (provider: string) => {
  const safePrefix = provider && provider.trim().length > 0 ? provider : 'node'
  return `${safePrefix}-${Date.now().toString(36)}`
}

export const useCloudViewMeta = ({
  cloudStore,
  form,
  hasApiKey,
  testingLatency,
  latencyResults,
  showLatencyResults,
  handleError,
  translate,
  testAllCloudRegions,
}: UseCloudViewMetaDeps) => {
  let refreshIntervalId: number | null = null

  const pickPlanForRegion = (region: string) => {
    const ids = cloudStore.availability[region] || []
    const fallback = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id))
    if (fallback) return fallback
    return cloudStore.plans[0]?.id || ''
  }

  const ensurePlanForRegion = (region: string) => {
    if (!region) return
    const ids = cloudStore.availability[region]
    if (!ids || ids.length === 0) return
    if (!ids.includes(form.plan)) {
      const replacement = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id)) || ''
      if (replacement) {
        form.plan = replacement
      }
    }
  }

  const applyDefaults = async () => {
    const validRegionIds = new Set(cloudStore.regions.map((region) => region.id))
    if (form.region && !validRegionIds.has(form.region)) {
      form.region = ''
    }

    const validPlanIds = new Set(cloudStore.plans.map((plan) => plan.id))
    if (form.plan && !validPlanIds.has(form.plan)) {
      form.plan = ''
    }

    if (!form.region) {
      const defaultRegion = cloudStore.config.defaultRegion
      const autoPickRegion = defaultRegion || (cloudStore.regions.length === 1 ? cloudStore.regions[0]?.id : '')
      form.region = autoPickRegion || ''
    }

    if (form.region) {
      await cloudStore.ensureRegionAvailability(form.region, true)
      if (!form.plan) {
        form.plan = cloudStore.config.defaultPlan || pickPlanForRegion(form.region)
      } else {
        ensurePlanForRegion(form.region)
      }
    } else if (!form.plan) {
      form.plan = cloudStore.config.defaultPlan || cloudStore.plans[0]?.id || ''
    }
  }

  const updateLatencyCache = (results: RegionLatency[]) => {
    cloudStore.latencyTestResults = {}
    results.forEach((result) => {
      if (result.status === 'ok') {
        cloudStore.latencyTestResults[result.code] = result.latency
      }
    })
    cloudStore.latencyUpdatedAt = Date.now()
  }

  const testLatencySilently = async () => {
    if (!hasApiKey.value || cloudStore.regions.length === 0 || testingLatency.value) {
      return
    }
    if (cloudStore.isLatencyCacheValid() && latencyResults.value.length > 0) {
      return
    }

    testingLatency.value = true
    try {
      const result = await testAllCloudRegions()
      if (!result.flag) {
        return
      }

      const results = JSON.parse(result.data) as RegionLatency[]
      latencyResults.value = results
      updateLatencyCache(results)

      if (!form.region) {
        const fastest = results.find((entry) => entry.status === 'ok')
        if (fastest) {
          form.region = fastest.code
        }
      }
    } catch (error) {
      logError('[CloudView] Latency test error:', error)
    } finally {
      testingLatency.value = false
    }
  }

  const handleTestLatency = async () => {
    if (!hasApiKey.value) {
      message.warn(translate('cloud.latency.noApiKey'))
      return
    }

    testingLatency.value = true
    latencyResults.value = []
    try {
      const result = await testAllCloudRegions()
      if (!result.flag) {
        throw new Error(result.data)
      }

      const results = JSON.parse(result.data) as RegionLatency[]
      latencyResults.value = results
      showLatencyResults.value = true
      updateLatencyCache(results)

      const fastest = results.find((entry) => entry.status === 'ok')
      if (fastest) {
        form.region = fastest.code
        message.success(
          translate('cloud.latency.testComplete', {
            region: fastest.name,
            latency: fastest.latency.toFixed(1),
          }),
        )
      } else {
        message.warn(translate('cloud.latency.noAvailableRegion'))
      }
    } catch (error) {
      logError('TestLatency', error)
      message.error(translate('cloud.latency.testFailed'))
    } finally {
      testingLatency.value = false
    }
  }

  const fetchMeta = async () => {
    try {
      await Promise.all([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
      await cloudStore.refreshInstances(true)
      await applyDefaults()
    } catch (error) {
      handleError(error)
    }
  }

  const handleProviderChange = async () => {
    try {
      await cloudStore.switchProvider(cloudStore.currentProvider)
      message.success(translate('cloud.provider.switched'))

      form.region = ''
      form.plan = ''
      form.label = defaultCloudLabel(cloudStore.currentProvider)

      if (hasApiKey.value) {
        await fetchMeta()
      }

      await applyDefaults()
    } catch (error) {
      logError('[CloudView] Failed to switch provider:', error)
      handleError(error)
    }
  }

  const handleSaveConfig = async () => {
    if (!hasApiKey.value) {
      message.error(translate('cloud.errors.apiKeyRequired'))
      return
    }
    try {
      await cloudStore.saveConfig()
      message.success('common.success')
      await fetchMeta()
    } catch (error) {
      handleError(error)
    }
  }

  const handleRefreshInstances = async () => {
    if (!hasApiKey.value) {
      message.error(translate('cloud.errors.apiKeyRequired'))
      return
    }
    try {
      await cloudStore.refreshInstances()
    } catch (error) {
      handleError(error)
    }
  }

  watch(
    () => [cloudStore.regions.length, cloudStore.plans.length, cloudStore.config.defaultPlan, cloudStore.config.defaultRegion],
    applyDefaults,
  )

  watch(
    () => [cloudStore.regions.length, hasApiKey.value] as const,
    ([regionsCount, hasKey]) => {
      if (regionsCount > 0 && hasKey && latencyResults.value.length === 0) {
        setTimeout(() => {
          testLatencySilently()
        }, 500)
      }
    },
    { immediate: true },
  )

  watch(
    () => form.region,
    async (value, oldValue) => {
      const isValidRegion = value && cloudStore.regions.some((region) => region.id === value)
      if (isValidRegion) {
        cloudStore.config.defaultRegion = value
      }

      if (value && value !== oldValue) {
        await cloudStore.ensureRegionAvailability(value, true)
        ensurePlanForRegion(value)
      }
    },
  )

  watch(
    () => form.plan,
    (value) => {
      const isValidPlan = value && cloudStore.plans.some((plan) => plan.id === value)
      if (isValidPlan) {
        cloudStore.config.defaultPlan = value
      }
    },
    { flush: 'post' },
  )

  watch(
    () => cloudStore.currentProvider,
    (provider, previous) => {
      if (!provider || provider === previous) {
        return
      }

      const trimmedLabel = form.label.trim()
      const previousPrefix = previous ? `${previous}-` : 'node-'
      const wasAutoGenerated =
        trimmedLabel.startsWith(previousPrefix) &&
        /^[0-9a-z]+$/i.test(trimmedLabel.slice(previousPrefix.length))

      if (!trimmedLabel || wasAutoGenerated) {
        form.label = defaultCloudLabel(provider)
      }
    },
  )

  onUnmounted(() => {
    if (refreshIntervalId !== null) {
      clearInterval(refreshIntervalId)
      refreshIntervalId = null
    }
    cloudStore.clearAllTimers()
  })

  onMounted(async () => {
    try {
      await Promise.allSettled([cloudStore.loadProviders(), cloudStore.getCurrentProvider()])
      await cloudStore.loadManualNodes()
      await cloudStore.loadConfig()

      if (cloudStore.config.apiKey) {
        await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])

        cloudStore.refreshInstances(true).catch((error) => {
          logError('[CloudView] Initial refresh failed:', error)
        })

        if (refreshIntervalId !== null) {
          clearInterval(refreshIntervalId)
        }
        refreshIntervalId = window.setInterval(() => {
          if (cloudStore.config.apiKey) {
            cloudStore.refreshInstances(true).catch((error) => {
              logError('[CloudView] Background refresh failed:', error)
            })
          }
        }, 30000)
      } else {
        await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
      }

      await applyDefaults()
    } catch (error) {
      logError('[CloudView] onMounted error:', error)
      cloudStore.loadingInstances = false
      handleError(error)
    }
  })

  return {
    applyDefaults,
    ensurePlanForRegion,
    handleProviderChange,
    handleRefreshInstances,
    handleSaveConfig,
    handleTestLatency,
    fetchMeta,
  }
}
