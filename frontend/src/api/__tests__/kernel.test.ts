import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  appSettingsStore: {
    app: {
      kernel: {
        profile: 'profile-1',
      },
    },
  },
  profilesStore: {
    getProfileById: vi.fn(),
  },
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useProfilesStore: () => mocks.profilesStore,
}))

import {
  deleteConnection,
  getConfigs,
  getConnections,
  getProxies,
  getProxyDelay,
  setConfigs,
  useProxy,
} from '../kernel'

const response = (options: {
  json?: unknown
  status?: number
} = {}): Response =>
  ({
    json: vi.fn().mockResolvedValue(options.json ?? {}),
    status: options.status ?? 200,
  }) as unknown as Response

describe('kernel api client', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response()))
    mocks.appSettingsStore.app.kernel.profile = 'profile-1'
    mocks.profilesStore.getProfileById.mockReturnValue({
      experimental: {
        clash_api: {
          external_controller: '0.0.0.0:9090',
          secret: 'secret-token',
        },
      },
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('injects profile controller port and bearer token before requests', async () => {
    vi.mocked(fetch).mockResolvedValueOnce(response({ json: { mode: 'rule' } }))

    await expect(getConfigs()).resolves.toEqual({ mode: 'rule' })

    expect(mocks.profilesStore.getProfileById).toHaveBeenCalledWith('profile-1')
    expect(fetch).toHaveBeenCalledWith(
      'http://127.0.0.1:9090/configs',
      expect.objectContaining({
        headers: { Authorization: 'Bearer secret-token' },
        method: 'GET',
      }),
    )
  })

  it('sends config, proxy, and connection mutations to the kernel API', async () => {
    vi.mocked(fetch)
      .mockResolvedValueOnce(response({ status: 204 }))
      .mockResolvedValueOnce(response({ status: 204 }))
      .mockResolvedValueOnce(response({ status: 204 }))

    await expect(setConfigs({ mode: 'global' })).resolves.toBeNull()
    await expect(deleteConnection('conn-1')).resolves.toBeNull()
    await expect(useProxy('Auto%20Group', 'Node A')).resolves.toBeNull()

    expect(fetch).toHaveBeenNthCalledWith(
      1,
      'http://127.0.0.1:9090/configs',
      expect.objectContaining({
        body: JSON.stringify({ mode: 'global' }),
        method: 'PATCH',
      }),
    )
    expect(fetch).toHaveBeenNthCalledWith(
      2,
      'http://127.0.0.1:9090/connections/conn-1',
      expect.objectContaining({ method: 'DELETE' }),
    )
    expect(fetch).toHaveBeenNthCalledWith(
      3,
      'http://127.0.0.1:9090/proxies/Auto%20Group',
      expect.objectContaining({
        body: JSON.stringify({ name: 'Node A' }),
        method: 'PUT',
      }),
    )
  })

  it('reads proxies, connections, and proxy delay with query parameters', async () => {
    vi.mocked(fetch)
      .mockResolvedValueOnce(response({ json: { proxies: {} } }))
      .mockResolvedValueOnce(response({ json: { connections: [] } }))
      .mockResolvedValueOnce(response({ json: { delay: 42 } }))

    await expect(getProxies()).resolves.toEqual({ proxies: {} })
    await expect(getConnections()).resolves.toEqual({ connections: [] })
    await expect(getProxyDelay('Node A', 'https://probe.test')).resolves.toEqual({ delay: 42 })

    expect(fetch).toHaveBeenNthCalledWith(
      1,
      'http://127.0.0.1:9090/proxies',
      expect.objectContaining({ method: 'GET' }),
    )
    expect(fetch).toHaveBeenNthCalledWith(
      2,
      'http://127.0.0.1:9090/connections',
      expect.objectContaining({ method: 'GET' }),
    )
    expect(fetch).toHaveBeenNthCalledWith(
      3,
      'http://127.0.0.1:9090/proxies/Node A/delay?url=https%3A%2F%2Fprobe.test&timeout=5000',
      expect.objectContaining({ method: 'GET' }),
    )
  })

  it('falls back to the default local controller when no profile is active', async () => {
    mocks.profilesStore.getProfileById.mockReturnValue(undefined)

    await getConfigs()

    expect(fetch).toHaveBeenCalledWith(
      'http://127.0.0.1:20123/configs',
      expect.objectContaining({
        method: 'GET',
      }),
    )
    expect(vi.mocked(fetch).mock.calls[0][1]).not.toHaveProperty('headers')
  })
})
