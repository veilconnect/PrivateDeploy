import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref, shallowRef } from 'vue'

const mocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  writeFile: vi.fn(),
  removeFile: vi.fn(),
  sampleID: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
  RemoveFile: mocks.removeFile,
}))

vi.mock('@/utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/utils')>()
  return {
    ...actual,
    debounce: (fn: (...args: any[]) => any) => fn,
    ignoredError: async (fn: (...args: any[]) => any, ...args: any[]) => {
      try {
        return await fn(...args)
      } catch {
        return undefined
      }
    },
    sampleID: mocks.sampleID,
  }
})

vi.mock('@/utils/logger', () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}))

import { RequestMethod } from '@/enums/app'
import { Outbound } from '@/enums/kernel'

import { protocolHealthPath } from '../constants'
import { subscriptionId, subscriptionPath } from '../helpers'
import { createSubscriptionApply } from '../subscriptionApply'

import type { ProtocolHealthMap } from '../constants'
import type { Subscription } from '@/types/app'
import type { CdnDeployment, CloudNode, ConnectivityResult } from '@/types/cloud'

const makeSubscription = (id: string, overrides: Partial<Subscription> = {}): Subscription => ({
  id,
  name: id,
  upload: 0,
  download: 0,
  total: 0,
  expire: 0,
  updateTime: 0,
  type: 'Manual',
  url: '',
  website: '',
  path: subscriptionPath(id),
  include: '',
  exclude: '',
  includeProtocol: '',
  excludeProtocol: '',
  proxyPrefix: '',
  disabled: false,
  inSecure: false,
  requestMethod: RequestMethod.Get,
  header: {
    request: {},
    response: {},
  },
  proxies: [],
  script: '',
  ...overrides,
})

const makeProfile = (subscription: string): IProfile => ({
  id: 'profile-1',
  name: 'Managed',
  log: {},
  experimental: {},
  inbounds: [],
  outbounds: [
    {
      id: 'selector',
      tag: 'Proxy',
      type: Outbound.Selector,
      outbounds: [{ id: subscription, tag: 'Tokyo', type: 'Subscription' }],
    } as IOutbound,
    {
      id: subscription,
      tag: 'Tokyo direct',
      type: Outbound.Selector,
      outbounds: [],
    } as IOutbound,
  ],
  route: {
    rules: [],
    rule_set: [],
    final: 'selector',
    auto_detect_interface: false,
    default_interface: '',
    find_process: false,
  },
  dns: {},
  mixin: {},
  script: [],
})

const makeNode = (overrides: Partial<CloudNode> = {}): CloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo',
  provider: 'vultr',
  status: 'active',
  region: 'nrt',
  plan: 'vc2-1c-1gb',
  ipv4: '203.0.113.10',
  ipv6: '',
  ssPort: 8388,
  ssPassword: 'ss-secret',
  hysteriaPort: 8443,
  hysteriaPassword: 'hy-secret',
  vlessPort: 443,
  vlessRelayPort: 2096,
  vlessUUID: 'uuid-1',
  vlessPublicKey: 'abc+/==',
  vlessShortId: 'abcd',
  trojanPort: 9443,
  trojanPassword: 'trojan-secret',
  ...overrides,
} as CloudNode)

const createHarness = (options: {
  subscriptions?: Subscription[]
  profiles?: IProfile[]
  protocolHealth?: ProtocolHealthMap
  cdnDeployment?: CdnDeployment | null
  running?: boolean
} = {}) => {
  const subscriptionMap = new Map((options.subscriptions ?? []).map((sub) => [sub.id, sub]))
  const profiles = options.profiles ?? []
  const protocolHealth = shallowRef<ProtocolHealthMap>(options.protocolHealth ?? {})
  const protocolHealthLoaded = ref(false)
  const reloadKernel = vi.fn().mockResolvedValue(undefined)
  const editProfile = vi.fn(async (id: string, profile: IProfile) => {
    const index = profiles.findIndex((item) => item.id === id)
    if (index >= 0) profiles[index] = profile
  })

  const api = createSubscriptionApply({
    protocolHealth,
    protocolHealthLoaded,
    subscribesStore: {
      subscribes: [...subscriptionMap.values()],
      getSubscribeById: (id) => subscriptionMap.get(id),
      addSubscribe: vi.fn(async (sub: Subscription) => {
        subscriptionMap.set(sub.id, sub)
      }),
      editSubscribe: vi.fn(async (id: string, sub: Subscription) => {
        subscriptionMap.set(id, sub)
      }),
      deleteSubscribe: vi.fn(async (id: string) => {
        subscriptionMap.delete(id)
      }),
    },
    profilesStore: {
      profiles,
      getProfileById: (id) => profiles.find((profile) => profile.id === id),
      addProfile: vi.fn(async (profile: IProfile) => {
        profiles.push(profile)
      }),
      editProfile,
    },
    appSettingsStore: {
      app: {
        kernel: { profile: '' },
        autoStartKernel: true,
      },
    },
    kernelApiStore: {
      running: options.running ?? false,
      restartCore: vi.fn(),
      startCore: vi.fn(),
      refreshProviderProxies: vi.fn(),
      removeProxyFromGroups: vi.fn(),
    },
    reloadKernel,
    cdnDeploymentFor: () => options.cdnDeployment ?? null,
  })

  return {
    api,
    protocolHealth,
    protocolHealthLoaded,
    subscriptionMap,
    profiles,
    reloadKernel,
  }
}

describe('createSubscriptionApply', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    vi.spyOn(console, 'log').mockImplementation(() => {})
    let id = 0
    mocks.sampleID.mockImplementation(() => `id-${++id}`)
    mocks.readFile.mockResolvedValue('')
    mocks.writeFile.mockResolvedValue(undefined)
    mocks.removeFile.mockResolvedValue(undefined)
  })

  it('creates a cloud subscription with protocol and CDN outbounds', async () => {
    const harness = createHarness({
      cdnDeployment: {
        nodeId: 'node-1',
        scriptName: 'pd-relay-node-1',
        workerHost: 'worker.example.workers.dev',
        backend: '203.0.113.10:2096',
        deployedAt: new Date().toISOString(),
        customHost: 'cdn.example.com',
        pathSecret: 'secret-token',
      } as CdnDeployment,
    })

    await harness.api.ensureSubscriptionForNode(makeNode({ ipv6: '2001:db8::10' }))

    expect(mocks.writeFile).toHaveBeenCalledWith(
      subscriptionPath('node-1'),
      expect.stringContaining('"Tokyo-cdn"'),
    )
    const payload = JSON.parse(mocks.writeFile.mock.calls[0][1])
    expect(payload.outbounds).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: 'shadowsocks', tag: 'Tokyo-ss-v4' }),
        expect.objectContaining({ type: 'shadowsocks', tag: 'Tokyo-ss-v6' }),
        expect.objectContaining({ type: 'hysteria2', tag: 'Tokyo-hysteria2-v4' }),
        expect.objectContaining({
          type: 'vless',
          tag: 'Tokyo-cdn',
          server: 'cdn.example.com',
          server_port: 443,
          transport: expect.objectContaining({
            path: '/?ed=2560&k=secret-token',
            headers: { Host: 'cdn.example.com' },
          }),
        }),
        expect.objectContaining({ type: 'trojan', tag: 'Tokyo-trojan-v4' }),
      ]),
    )
    expect(harness.subscriptionMap.get(subscriptionId('node-1'))).toMatchObject({
      id: 'cloud-node-1',
      name: 'Tokyo',
      path: subscriptionPath('node-1'),
      requestMethod: RequestMethod.Get,
    })
  })

  it('removes a subscription and prunes profile references when a node has no usable address', async () => {
    const id = subscriptionId('node-1')
    const harness = createHarness({
      subscriptions: [makeSubscription(id)],
      profiles: [makeProfile(id)],
      running: true,
    })

    await harness.api.ensureSubscriptionForNode(makeNode({ ipv4: '10.0.0.1', ipv6: '' }))

    expect(harness.subscriptionMap.has(id)).toBe(false)
    expect(mocks.removeFile).toHaveBeenCalledWith(subscriptionPath('node-1'))
    expect(harness.profiles[0].outbounds).toHaveLength(1)
    expect((harness.profiles[0].outbounds[0] as any).outbounds).toEqual([])
    expect(harness.reloadKernel).toHaveBeenCalledWith('remove-subscription', {
      allowStartWhenStopped: false,
    })
  })

  it('updates protocol health from connectivity results and applies managed excludes', async () => {
    const id = subscriptionId('node-1')
    const existing = makeSubscription(id, {
      exclude: 'user-rule',
      updateTime: 1_600_000_000_000,
    })
    const harness = createHarness({
      subscriptions: [existing],
    })
    const result: ConnectivityResult = {
      targetStatus: {
        'shadowsocks-tcp': 'open',
        'vless-reality': 'open',
        trojan: 'closed',
        hysteria2: 'closed',
      },
    } as ConnectivityResult

    await harness.api.updateProtocolHealthFromConnectivity(makeNode(), result)

    expect(mocks.writeFile).toHaveBeenCalledWith(
      protocolHealthPath,
      expect.stringContaining('"hysteria2"'),
    )
    expect(harness.protocolHealth.value['node-1']).toMatchObject({
      hysteria2: { state: 'degraded', reason: 'connectivity-udp-unreachable' },
      trojan: { state: 'degraded', reason: 'connectivity-tcp-unreachable' },
    })

    const updated = harness.subscriptionMap.get(id)
    expect(updated?.header?.response?.['x-privatedeploy-user-exclude']).toBe('user-rule')
    expect(updated?.header?.response?.['x-privatedeploy-managed-exclude']).toContain('hysteria')
    expect(updated?.header?.response?.['x-privatedeploy-managed-exclude']).toContain('trojan')
    expect(updated?.exclude).toContain('user-rule')
    expect(updated?.exclude).toContain('trojan')
  })
})
