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

describe('useCloudViewMeta', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
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
