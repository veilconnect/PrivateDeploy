import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  clearCdn: vi.fn(),
  clearCdnCustomDomain: vi.fn(),
  deleteCdnWorkerForNode: vi.fn(),
  deployCdnWorkerForNode: vi.fn(),
  eventsOff: vi.fn(),
  eventsOn: vi.fn(),
  getCdnState: vi.fn(),
  listCdnZones: vi.fn(),
  setCdnCustomDomain: vi.fn(),
  stateHandler: undefined as undefined | ((state: any) => void),
  verifyCdnToken: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ClearCdn: mocks.clearCdn,
  ClearCdnCustomDomain: mocks.clearCdnCustomDomain,
  DeleteCdnWorkerForNode: mocks.deleteCdnWorkerForNode,
  DeployCdnWorkerForNode: mocks.deployCdnWorkerForNode,
  EventsOff: mocks.eventsOff,
  EventsOn: mocks.eventsOn,
  GetCdnState: mocks.getCdnState,
  ListCdnZones: mocks.listCdnZones,
  SetCdnCustomDomain: mocks.setCdnCustomDomain,
  VerifyCdnToken: mocks.verifyCdnToken,
}))

import { useCdnStore } from '../cdn'

const verifiedState = (overrides: Record<string, unknown> = {}) => ({
  accountEmail: 'ops@example.com',
  accountId: 'account-1',
  customDomain: null,
  deployments: {},
  status: 'verified',
  workersDevExample: 'node-a.pd.workers.dev',
  workersSubdomain: 'pd',
  ...overrides,
})

describe('cdn store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())
    mocks.stateHandler = undefined

    mocks.eventsOn.mockImplementation((_event: string, handler: (state: any) => void) => {
      mocks.stateHandler = handler
    })
    mocks.getCdnState.mockResolvedValue(verifiedState())
    mocks.verifyCdnToken.mockResolvedValue({ ok: true, state: verifiedState() })
    mocks.clearCdn.mockResolvedValue({ deployments: {}, status: 'disabled' })
    mocks.deployCdnWorkerForNode.mockResolvedValue({
      ok: true,
      state: verifiedState({
        deployments: {
          'node-1': {
            nodeId: 'node-1',
            status: 'deployed',
            workerUrl: 'https://node-1.pd.workers.dev',
          },
        },
      }),
    })
    mocks.deleteCdnWorkerForNode.mockResolvedValue({
      ok: true,
      state: verifiedState({ deployments: {} }),
    })
    mocks.listCdnZones.mockResolvedValue([
      { id: 'zone-1', name: 'example.com' },
      { id: 'zone-2', name: 'example.net' },
    ])
    mocks.setCdnCustomDomain.mockResolvedValue({
      ok: true,
      state: verifiedState({
        customDomain: {
          subdomain: 'edge',
          zoneId: 'zone-1',
          zoneName: 'example.com',
        },
      }),
    })
    mocks.clearCdnCustomDomain.mockResolvedValue(verifiedState({ customDomain: null }))
  })

  it('loads state and exposes derived CDN metadata', async () => {
    mocks.getCdnState.mockResolvedValue(verifiedState({
      customDomain: {
        subdomain: 'edge',
        zoneId: 'zone-1',
        zoneName: 'example.com',
      },
      deployments: {
        'node-1': {
          customHost: 'edge-node-1.example.com',
          nodeId: 'node-1',
          status: 'deployed',
        },
      },
      lastError: 'last failure',
    }))

    const store = useCdnStore()

    expect(store.initialized).toBe(false)
    await store.ensureLoaded()
    await store.ensureLoaded()

    expect(mocks.getCdnState).toHaveBeenCalledTimes(1)
    expect(store.status).toBe('verified')
    expect(store.isConfigured).toBe(true)
    expect(store.isVerified).toBe(true)
    expect(store.lastError).toBe('last failure')
    expect(store.accountId).toBe('account-1')
    expect(store.accountEmail).toBe('ops@example.com')
    expect(store.workersSubdomain).toBe('pd')
    expect(store.workersDevExample).toBe('node-a.pd.workers.dev')
    expect(store.customDomainHostPattern).toBe('edge-<node>.example.com')
    expect(store.deploymentFor('node-1')).toMatchObject({
      customHost: 'edge-node-1.example.com',
      nodeId: 'node-1',
    })
    expect(store.deploymentFor('missing')).toBeNull()
  })

  it('verifies and clears tokens while resetting cached zones', async () => {
    const store = useCdnStore()

    await store.refreshZones()
    expect(store.zones).toHaveLength(2)

    await expect(store.verify('token')).resolves.toBe(true)

    expect(mocks.verifyCdnToken).toHaveBeenCalledWith('token')
    expect(store.verifying).toBe(false)
    expect(store.zones).toEqual([])
    expect(store.zonesLoadedAt).toBeNull()

    await expect(store.clear()).resolves.toBeUndefined()
    expect(store.status).toBe('disabled')
    expect(store.zones).toEqual([])
  })

  it('guards concurrent verify, deploy, remove, and custom-domain operations', async () => {
    const store = useCdnStore()

    let resolveVerify: (value: { ok: boolean; state: any }) => void = () => undefined
    mocks.verifyCdnToken.mockImplementationOnce(() => {
      return new Promise((resolve) => {
        resolveVerify = resolve
      })
    })
    const firstVerify = store.verify('token-1')
    await expect(store.verify('token-2')).resolves.toBe(false)
    resolveVerify({ ok: true, state: verifiedState() })
    await expect(firstVerify).resolves.toBe(true)

    let resolveDeploy: (value: { ok: boolean; state: any }) => void = () => undefined
    mocks.deployCdnWorkerForNode.mockImplementationOnce(() => {
      return new Promise((resolve) => {
        resolveDeploy = resolve
      })
    })
    const firstDeploy = store.deploy('node-1')
    await expect(store.deploy('node-2')).resolves.toBe(false)
    expect(store.deployingFor).toBe('node-1')
    resolveDeploy({ ok: true, state: verifiedState() })
    await expect(firstDeploy).resolves.toBe(true)
    expect(store.deployingFor).toBeNull()

    let resolveRemove: (value: { ok: boolean; state: any }) => void = () => undefined
    mocks.deleteCdnWorkerForNode.mockImplementationOnce(() => {
      return new Promise((resolve) => {
        resolveRemove = resolve
      })
    })
    const firstRemove = store.remove('node-1')
    await expect(store.remove('node-2')).resolves.toBe(false)
    expect(store.deletingFor).toBe('node-1')
    resolveRemove({ ok: true, state: verifiedState() })
    await expect(firstRemove).resolves.toBe(true)
    expect(store.deletingFor).toBeNull()

    let resolveDomain: (value: { ok: boolean; state: any }) => void = () => undefined
    mocks.setCdnCustomDomain.mockImplementationOnce(() => {
      return new Promise((resolve) => {
        resolveDomain = resolve
      })
    })
    const firstDomain = store.setCustomDomain('zone-1', 'edge')
    await expect(store.setCustomDomain('zone-2', 'edge')).resolves.toBe(false)
    await expect(store.clearCustomDomain()).resolves.toBeUndefined()
    expect(store.savingCustomDomain).toBe(true)
    resolveDomain({ ok: true, state: verifiedState() })
    await expect(firstDomain).resolves.toBe(true)
    expect(store.savingCustomDomain).toBe(false)
  })

  it('refreshes zones and applies bridge events until disposed', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(123456)
    const store = useCdnStore()

    await expect(store.refreshZones()).resolves.toEqual([
      { id: 'zone-1', name: 'example.com' },
      { id: 'zone-2', name: 'example.net' },
    ])
    expect(store.zonesLoadedAt).toBe(123456)
    expect(store.zonesLoading).toBe(false)

    mocks.stateHandler?.(verifiedState({ accountId: 'account-2' }))
    expect(store.accountId).toBe('account-2')

    mocks.stateHandler?.(null)
    expect(store.accountId).toBe('account-2')

    store.dispose()
    expect(mocks.eventsOff).toHaveBeenCalledWith('cdn:state')

    mocks.stateHandler?.(verifiedState({ accountId: 'account-3' }))
    expect(store.accountId).toBe('account-2')
  })
})
