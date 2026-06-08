import { beforeEach, describe, expect, it, vi } from 'vitest'
import { reactive, ref, shallowRef } from 'vue'

const mocks = vi.hoisted(() => ({
  getCloudConfig: vi.fn(),
  saveCloudConfig: vi.fn(),
  listCloudProviders: vi.fn(),
  getCloudProvider: vi.fn(),
  setCloudProvider: vi.fn(),
  listCloudRegions: vi.fn(),
  listCloudPlans: vi.fn(),
  listCloudAvailability: vi.fn(),
  retryWithBackoff: vi.fn((fn: () => Promise<unknown>) => fn()),
  configSaved: vi.fn(),
  notifyError: vi.fn(),
  isOnline: { value: true },
  saveToOfflineCache: vi.fn(),
  loadFromOfflineCache: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  GetCloudConfig: mocks.getCloudConfig,
  SaveCloudConfig: mocks.saveCloudConfig,
  ListCloudProviders: mocks.listCloudProviders,
  GetCloudProvider: mocks.getCloudProvider,
  SetCloudProvider: mocks.setCloudProvider,
  ListCloudRegions: mocks.listCloudRegions,
  ListCloudPlans: mocks.listCloudPlans,
  ListCloudAvailability: mocks.listCloudAvailability,
}))

vi.mock('@/utils/errorRecovery', () => ({
  retryWithBackoff: mocks.retryWithBackoff,
}))

vi.mock('@/utils/logger', () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}))

vi.mock('@/utils/notification', () => ({
  notifications: {
    configSaved: mocks.configSaved,
    error: mocks.notifyError,
  },
}))

vi.mock('@/utils/offline', () => ({
  isOnline: mocks.isOnline,
  saveToOfflineCache: mocks.saveToOfflineCache,
  loadFromOfflineCache: mocks.loadFromOfflineCache,
}))

import { createProviderConfig } from '../providerConfig'

import type { CloudConfig, CloudPlan, CloudProvider, CloudRegion } from '@/types/cloud'

const region = {
  id: 'nrt',
  city: 'Tokyo',
  country: 'Japan',
  continent: 'Asia',
} as CloudRegion

const plan = {
  id: 'vc2-1c-1gb',
  ram: 1024,
  vcpuCount: 1,
  disk: 25,
  monthlyCost: 6,
  locations: ['nrt'],
} as CloudPlan

const createHarness = () => {
  const availableProviders = ref<Array<{ name: string; displayName: string }>>([])
  const currentProvider = ref<CloudProvider>('vultr')
  const config = reactive<CloudConfig>({
    apiKey: '',
    defaultPlan: '',
    defaultRegion: '',
    extra: {},
  })
  const configLoaded = ref(false)
  const savingConfig = ref(false)
  const regions = shallowRef<CloudRegion[]>([])
  const plans = shallowRef<CloudPlan[]>([])
  const availability = reactive<Record<string, string[]>>({})
  const loadingRegions = ref(false)
  const loadingPlans = ref(false)
  const regionsUpdatedAt = ref<number | null>(null)
  const plansUpdatedAt = ref<number | null>(null)
  const instances = shallowRef<any[]>([])
  const instancesUpdatedAt = ref<number | null>(null)
  const accountStatus = ref<any | null>(null)
  const startAutoRefresh = vi.fn()
  const stopAutoRefresh = vi.fn()
  const refreshInstances = vi.fn().mockResolvedValue(undefined)

  const api = createProviderConfig({
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
    accountStatus,
    startAutoRefresh,
    stopAutoRefresh,
    refreshInstances,
  })

  return {
    api,
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
    startAutoRefresh,
    stopAutoRefresh,
    refreshInstances,
  }
}

describe('createProviderConfig', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    vi.spyOn(console, 'log').mockImplementation(() => {})
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    mocks.isOnline.value = true
    mocks.getCloudProvider.mockResolvedValue({ name: 'vultr', displayName: 'Vultr' })
    mocks.getCloudConfig.mockResolvedValue({
      apiKey: '',
      defaultPlan: '',
      defaultRegion: '',
      extra: {},
    })
    mocks.saveCloudConfig.mockResolvedValue(undefined)
    mocks.listCloudRegions.mockResolvedValue([region])
    mocks.listCloudPlans.mockResolvedValue([plan])
    mocks.listCloudAvailability.mockResolvedValue(['vc2-1c-1gb'])
    mocks.listCloudProviders.mockResolvedValue([{ name: 'vultr', displayName: 'Vultr' }])
    mocks.setCloudProvider.mockResolvedValue({ name: 'ssh', displayName: 'SSH' })
    mocks.loadFromOfflineCache.mockReturnValue(null)
  })

  it('loads cloud config and starts or stops auto-refresh based on API key presence', async () => {
    const harness = createHarness()
    mocks.getCloudConfig.mockResolvedValueOnce({
      apiKey: 'token',
      defaultPlan: 'vc2-1c-1gb',
      defaultRegion: 'nrt',
      provider: 'vultr',
      extra: { account: 'primary' },
    })

    await harness.api.loadConfig()

    expect(harness.config).toMatchObject({
      apiKey: 'token',
      defaultPlan: 'vc2-1c-1gb',
      defaultRegion: 'nrt',
      provider: 'vultr',
      extra: { account: 'primary' },
    })
    expect(harness.configLoaded.value).toBe(true)
    expect(harness.startAutoRefresh).toHaveBeenCalledWith(true)
    expect(harness.stopAutoRefresh).not.toHaveBeenCalled()

    mocks.getCloudConfig.mockResolvedValueOnce({
      apiKey: '',
      defaultPlan: '',
      defaultRegion: '',
      extra: {},
    })
    await harness.api.loadConfig()
    expect(harness.stopAutoRefresh).toHaveBeenCalledTimes(1)
  })

  it('saves config using the backend active provider and resets saving state', async () => {
    const harness = createHarness()
    Object.assign(harness.config, {
      apiKey: 'token',
      defaultPlan: 'vc2-1c-1gb',
      defaultRegion: 'nrt',
      extra: { project: 'edge' },
    })
    mocks.getCloudProvider.mockResolvedValueOnce({ name: 'digitalocean' })

    await harness.api.saveConfig()

    expect(harness.currentProvider.value).toBe('digitalocean')
    expect(mocks.retryWithBackoff).toHaveBeenCalled()
    expect(mocks.saveCloudConfig).toHaveBeenCalledWith({
      apiKey: 'token',
      defaultPlan: 'vc2-1c-1gb',
      defaultRegion: 'nrt',
      extra: { project: 'edge' },
      provider: 'digitalocean',
    })
    expect(harness.startAutoRefresh).toHaveBeenCalledWith(true)
    expect(mocks.configSaved).toHaveBeenCalledTimes(1)
    expect(harness.savingConfig.value).toBe(false)
  })

  it('uses region and plan caches before calling bridge APIs', async () => {
    const harness = createHarness()
    harness.regions.value = [region]
    harness.plans.value = [plan]
    harness.regionsUpdatedAt.value = Date.now()
    harness.plansUpdatedAt.value = Date.now()

    await harness.api.fetchRegions()
    await harness.api.fetchPlans()

    expect(mocks.listCloudRegions).not.toHaveBeenCalled()
    expect(mocks.listCloudPlans).not.toHaveBeenCalled()
  })

  it('loads offline cached regions when offline and updates cache after online fetches', async () => {
    const harness = createHarness()
    mocks.isOnline.value = false
    mocks.loadFromOfflineCache.mockReturnValueOnce([region])

    await harness.api.fetchRegions()

    expect(harness.regions.value).toEqual([region])
    expect(mocks.listCloudRegions).not.toHaveBeenCalled()

    mocks.isOnline.value = true
    await harness.api.fetchPlans(true)

    expect(harness.plans.value).toEqual([plan])
    expect(mocks.saveToOfflineCache).toHaveBeenCalledWith('plans', [plan])
    expect(harness.loadingPlans.value).toBe(false)
  })

  it('guards availability lookups until an API key is configured', async () => {
    const harness = createHarness()

    await expect(harness.api.ensureRegionAvailability('nrt')).resolves.toEqual([])
    expect(mocks.listCloudAvailability).not.toHaveBeenCalled()

    harness.config.apiKey = 'token'
    await expect(harness.api.ensureRegionAvailability('nrt', true)).resolves.toEqual([
      'vc2-1c-1gb',
    ])
    expect(mocks.listCloudAvailability).toHaveBeenCalledWith('nrt')
  })

  it('loads providers with fallback and switches providers with clean provider-scoped state', async () => {
    const harness = createHarness()
    harness.config.apiKey = ''
    harness.regions.value = [region]
    harness.plans.value = [plan]
    harness.availability.nrt = ['vc2-1c-1gb']
    mocks.listCloudProviders.mockRejectedValueOnce(new Error('offline'))
    mocks.getCloudConfig.mockResolvedValueOnce({
      apiKey: '',
      defaultPlan: 'old-plan',
      defaultRegion: 'old-region',
      extra: {},
    })

    await harness.api.loadProviders()
    expect(harness.availableProviders.value).toEqual([{ name: 'vultr', displayName: 'Vultr' }])

    await harness.api.switchProvider('ssh')

    expect(mocks.setCloudProvider).toHaveBeenCalledWith('ssh')
    expect(harness.currentProvider.value).toBe('ssh')
    expect(harness.regions.value).toEqual([])
    expect(harness.plans.value).toEqual([])
    expect(harness.availability).toEqual({})
    expect(harness.config.defaultRegion).toBe('')
    expect(harness.config.defaultPlan).toBe('')
    expect(harness.refreshInstances).toHaveBeenCalledWith(true, true)
  })
})
