import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, h, reactive, ref, nextTick } from 'vue'

const messageMocks = vi.hoisted(() => ({
  info: vi.fn(),
  success: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
}))

vi.mock('@/utils', () => ({
  message: {
    info: messageMocks.info,
    success: messageMocks.success,
    warn: messageMocks.warn,
    error: messageMocks.error,
  },
}))

import { useCloudViewMeta } from '../useCloudViewMeta'

const mountComposable = async (factory: () => unknown) => {
  let exposed: unknown
  const el = document.createElement('div')
  const app = createApp({
    setup() {
      exposed = factory()
      return () => h('div')
    },
  })
  app.mount(el)
  await nextTick()
  return {
    result: exposed,
    unmount: () => app.unmount(),
  }
}

const makeCloudStore = (overrides: Record<string, unknown> = {}) => ({
  regions: [{ id: 'nrt' }],
  plans: [{ id: 'vc2-1c-1gb' }],
  instances: [],
  availability: {},
  config: { apiKey: 'key', defaultRegion: '', defaultPlan: '' },
  loadingInstances: false,
  latencyTestResults: {},
  latencyUpdatedAt: null,
  currentProvider: 'vultr',
  isLatencyCacheValid: vi.fn(() => false),
  ensureRegionAvailability: vi.fn().mockResolvedValue([]),
  fetchRegions: vi.fn().mockResolvedValue(undefined),
  fetchPlans: vi.fn().mockResolvedValue(undefined),
  refreshInstances: vi.fn().mockResolvedValue(undefined),
  loadProviders: vi.fn().mockResolvedValue(undefined),
  getCurrentProvider: vi.fn().mockResolvedValue(undefined),
  loadManualNodes: vi.fn().mockResolvedValue(undefined),
  loadConfig: vi.fn().mockResolvedValue(undefined),
  switchProvider: vi.fn().mockResolvedValue(undefined),
  saveConfig: vi.fn().mockResolvedValue(undefined),
  clearAllTimers: vi.fn(),
  ...overrides,
})

const region = (code: string, latency: number, status = 'ok') => ({
  code,
  name: code.toUpperCase(),
  ip: '203.0.113.1',
  latency,
  loss: 0,
  status,
})

describe('useCloudViewMeta', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    const store: Record<string, string> = {}
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v)
      },
      removeItem: (k: string) => {
        delete store[k]
      },
      clear: () => {
        for (const k of Object.keys(store)) delete store[k]
      },
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('restores persisted region latency on cold mount and pre-selects fastest', async () => {
    localStorage.setItem(
      'cloud-region-latency-v1',
      JSON.stringify({
        // Persisted in backend order (latency-sorted, fastest first).
        provider: 'vultr',
        ts: Date.now(),
        results: [region('nrt', 40), region('fra', 90)],
      }),
    )
    const cloudStore = makeCloudStore()
    const latencyResults = ref<ReturnType<typeof region>[]>([])
    const form = reactive({ label: '', region: '', plan: '' })

    const { unmount } = await mountComposable(() =>
      useCloudViewMeta({
        cloudStore: cloudStore as any,
        form,
        hasApiKey: ref(true),
        testingLatency: ref(false),
        latencyResults,
        showLatencyResults: ref(false),
        handleError: vi.fn(),
        translate: (key: string) => key,
        testAllCloudRegions: vi.fn().mockResolvedValue({ flag: true, data: '[]' }),
      }),
    )

    expect(latencyResults.value).toHaveLength(2)
    expect(cloudStore.latencyUpdatedAt).not.toBeNull()
    expect(form.region).toBe('nrt') // fastest reachable (40ms) auto-selected
    unmount()
  })

  it('does not restore cache from a different provider', async () => {
    localStorage.setItem(
      'cloud-region-latency-v1',
      JSON.stringify({ provider: 'digitalocean', ts: Date.now(), results: [region('nyc1', 10)] }),
    )
    const latencyResults = ref<ReturnType<typeof region>[]>([])

    const { unmount } = await mountComposable(() =>
      useCloudViewMeta({
        cloudStore: makeCloudStore({ currentProvider: 'vultr' }) as any,
        form: reactive({ label: '', region: '', plan: '' }),
        hasApiKey: ref(true),
        testingLatency: ref(false),
        latencyResults,
        showLatencyResults: ref(false),
        handleError: vi.fn(),
        translate: (key: string) => key,
        testAllCloudRegions: vi.fn().mockResolvedValue({ flag: true, data: '[]' }),
      }),
    )

    expect(latencyResults.value).toHaveLength(0)
    unmount()
  })

  it('does not restore cache older than the max age', async () => {
    const fourDaysMs = 4 * 24 * 60 * 60 * 1000
    localStorage.setItem(
      'cloud-region-latency-v1',
      JSON.stringify({ provider: 'vultr', ts: Date.now() - fourDaysMs, results: [region('nrt', 40)] }),
    )
    const latencyResults = ref<ReturnType<typeof region>[]>([])

    const { unmount } = await mountComposable(() =>
      useCloudViewMeta({
        cloudStore: makeCloudStore() as any,
        form: reactive({ label: '', region: '', plan: '' }),
        hasApiKey: ref(true),
        testingLatency: ref(false),
        latencyResults,
        showLatencyResults: ref(false),
        handleError: vi.fn(),
        translate: (key: string) => key,
        testAllCloudRegions: vi.fn().mockResolvedValue({ flag: true, data: '[]' }),
      }),
    )

    expect(latencyResults.value).toHaveLength(0) // stale → dropped
    unmount()
  })

  it('persists probe results to localStorage', async () => {
    const cloudStore = makeCloudStore()
    const probed = [region('sjc', 77), region('icn', 55)]

    const { result, unmount } = await mountComposable(() =>
      useCloudViewMeta({
        cloudStore: cloudStore as any,
        form: reactive({ label: '', region: '', plan: '' }),
        hasApiKey: ref(true),
        testingLatency: ref(false),
        latencyResults: ref([]),
        showLatencyResults: ref(false),
        handleError: vi.fn(),
        translate: (key: string) => key,
        testAllCloudRegions: vi
          .fn()
          .mockResolvedValue({ flag: true, data: JSON.stringify(probed) }),
      }),
    )

    await (result as ReturnType<typeof useCloudViewMeta>).handleTestLatency()

    const raw = localStorage.getItem('cloud-region-latency-v1')
    expect(raw).toBeTruthy()
    const parsed = JSON.parse(raw as string)
    expect(parsed.provider).toBe('vultr')
    expect(parsed.results.map((r: { code: string }) => r.code)).toEqual(['sjc', 'icn'])
    unmount()
  })

  it('forces a remote instance refresh after saving cloud credentials', async () => {
    const cloudStore = {
      regions: [{ id: 'nrt' }],
      plans: [{ id: 'vc2-1c-1gb' }],
      instances: [{ instanceId: 'node-1' }],
      availability: { nrt: ['vc2-1c-1gb'] },
      config: { apiKey: 'key', defaultRegion: '', defaultPlan: '' },
      loadingInstances: false,
      latencyTestResults: {},
      latencyUpdatedAt: null,
      currentProvider: 'vultr',
      isLatencyCacheValid: vi.fn(() => false),
      ensureRegionAvailability: vi.fn().mockResolvedValue(['vc2-1c-1gb']),
      fetchRegions: vi.fn().mockResolvedValue(undefined),
      fetchPlans: vi.fn().mockResolvedValue(undefined),
      refreshInstances: vi.fn().mockResolvedValue(undefined),
      loadProviders: vi.fn().mockResolvedValue(undefined),
      getCurrentProvider: vi.fn().mockResolvedValue(undefined),
      loadManualNodes: vi.fn().mockResolvedValue(undefined),
      loadConfig: vi.fn().mockResolvedValue(undefined),
      switchProvider: vi.fn().mockResolvedValue(undefined),
      saveConfig: vi.fn().mockResolvedValue(undefined),
      clearAllTimers: vi.fn(),
    }

    const { result, unmount } = await mountComposable(() => useCloudViewMeta({
      cloudStore: cloudStore as any,
      form: reactive({ label: 'vultr-test', region: '', plan: '' }),
      hasApiKey: ref(true),
      testingLatency: ref(false),
      latencyResults: ref([]),
      showLatencyResults: ref(false),
      handleError: vi.fn(),
      translate: (key: string, params?: Record<string, unknown>) =>
        key === 'cloud.credentials.syncedNodes' ? `Synced ${params?.count} deployed node(s).` : key,
      testAllCloudRegions: vi.fn().mockResolvedValue({ flag: true, data: '[]' }),
    }))

    vi.clearAllMocks()

    await (result as ReturnType<typeof useCloudViewMeta>).handleSaveConfig()

    expect(cloudStore.saveConfig).toHaveBeenCalledTimes(1)
    expect(cloudStore.refreshInstances).toHaveBeenCalledWith(true, true)
    expect(messageMocks.info).toHaveBeenCalledWith('Synced 1 deployed node(s).')

    unmount()
  })
})
