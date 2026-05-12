import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref, shallowRef } from 'vue'

const mocks = vi.hoisted(() => ({
  listCloudInstances: vi.fn(),
  createCloudInstance: vi.fn(),
  createMultipleCloudInstances: vi.fn(),
  destroyCloudInstance: vi.fn(),
  testConnectivity: vi.fn(),
  testNodeDirectSpeed: vi.fn(),
  readFile: vi.fn(),
  retryWithBackoff: vi.fn((fn: () => Promise<unknown>) => fn()),
  isOnline: { value: true },
  saveToOfflineCache: vi.fn(),
  loadFromOfflineCache: vi.fn(),
  notifications: {
    deploymentComplete: vi.fn(),
    deploymentFailed: vi.fn(),
    connectivityBlocked: vi.fn(),
    connectivityRestored: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
    rotationComplete: vi.fn(),
    rotationFailed: vi.fn(),
  },
}))

vi.mock('@/bridge', () => ({
  ListCloudInstances: mocks.listCloudInstances,
  CreateCloudInstance: mocks.createCloudInstance,
  CreateMultipleCloudInstances: mocks.createMultipleCloudInstances,
  DestroyCloudInstance: mocks.destroyCloudInstance,
  TestConnectivity: mocks.testConnectivity,
  TestNodeDirectSpeed: mocks.testNodeDirectSpeed,
  ReadFile: mocks.readFile,
}))

vi.mock('@/utils/errorRecovery', () => ({
  retryWithBackoff: mocks.retryWithBackoff,
}))

vi.mock('@/utils/logger', () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}))

vi.mock('@/utils/notification', () => ({
  notifications: mocks.notifications,
}))

vi.mock('@/utils/offline', () => ({
  isOnline: mocks.isOnline,
  saveToOfflineCache: mocks.saveToOfflineCache,
  loadFromOfflineCache: mocks.loadFromOfflineCache,
}))

import { Outbound } from '@/enums/kernel'

import { subscriptionId } from '../helpers'
import { createInstanceSync } from '../instanceSync'

import type { ManagedCloudNode } from '../types'
import type { CloudProvider } from '@/types/cloud'

const readyNode = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo',
  provider: 'vultr',
  status: 'active',
  statusText: 'connected',
  region: 'nrt',
  plan: 'vc2-1c-1gb',
  ipv4: '203.0.113.10',
  ssPort: 8388,
  ssPassword: 'secret',
  ...overrides,
} as ManagedCloudNode)

const profileWithCloudSubscription = (instanceId = 'node-1'): IProfile => ({
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
      outbounds: [{ id: subscriptionId(instanceId), tag: 'Tokyo', type: 'Subscription' }],
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

const createHarness = (options: {
  instances?: ManagedCloudNode[]
  manualNodes?: ManagedCloudNode[]
  profile?: IProfile
  running?: boolean
} = {}) => {
  const instances = shallowRef<ManagedCloudNode[]>(options.instances ?? [])
  const manualNodes = shallowRef<ManagedCloudNode[]>(options.manualNodes ?? [])
  const instancesUpdatedAt = ref<number | null>(null)
  const loadingInstances = ref(false)
  const creatingInstance = ref(false)
  const destroyingInstance = ref('')
  const currentProvider = ref<CloudProvider>('vultr')
  const recordConnectivitySample = vi.fn().mockResolvedValue(undefined)
  const recordSpeedSample = vi.fn().mockResolvedValue(undefined)
  const syncManualNodesIntoInstances = vi.fn()
  const saveManualNodes = vi.fn().mockResolvedValue(undefined)
  const ensureSubscriptionForNode = vi.fn().mockResolvedValue(undefined)
  const removeSubscriptionForNode = vi.fn().mockResolvedValue(undefined)
  const applyNodeToProfile = vi.fn().mockResolvedValue('profile-1')
  const applyAllNodesToProfile = vi.fn().mockResolvedValue([])
  const reloadKernel = vi.fn().mockResolvedValue(undefined)

  const api = createInstanceSync({
    config: { apiKey: 'token' },
    currentProvider,
    instances,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    manualNodes,
    latencyTestResults: ref({}),
    latencyUpdatedAt: ref(null),
    multiDeployProgress: ref(new Map()),
    appSettingsStore: {
      app: {
        kernel: { profile: options.profile?.id ?? '' },
        autoStartKernel: true,
      },
    },
    profilesStore: {
      getProfileById: () => options.profile,
    },
    kernelApiStore: {
      running: options.running ?? false,
      config: {},
      proxies: {},
      refreshProviderProxies: vi.fn().mockResolvedValue(undefined),
      addCloudNodeToGroups: vi.fn(),
      getProxyPort: vi.fn(),
    },
    subscribesStore: {
      subscribes: [{ id: subscriptionId('node-1') }],
    },
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity: vi.fn().mockResolvedValue(false),
    applyNodeToProfile,
    applyAllNodesToProfile,
    loadNodeHistory: vi.fn().mockResolvedValue(undefined),
    migrateNodeHistory: vi.fn().mockResolvedValue(false),
    recordConnectivitySample,
    recordSpeedSample,
    loadManualNodes: vi.fn().mockResolvedValue(manualNodes.value),
    syncManualNodesIntoInstances,
    saveManualNodes,
    ensureRegionAvailability: vi.fn().mockResolvedValue([]),
    updateProtocolHealthFromConnectivity: vi.fn().mockResolvedValue(undefined),
    reloadKernel,
    markNodeStatus: vi.fn(),
  })

  return {
    api,
    instances,
    manualNodes,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    applyNodeToProfile,
    applyAllNodesToProfile,
    syncManualNodesIntoInstances,
    saveManualNodes,
    recordConnectivitySample,
    recordSpeedSample,
    reloadKernel,
  }
}

describe('createInstanceSync', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    mocks.isOnline.value = true
    mocks.loadFromOfflineCache.mockReturnValue(null)
    mocks.listCloudInstances.mockResolvedValue([readyNode()])
    mocks.testConnectivity.mockResolvedValue({
      status: 'reachable',
      targetStatus: { 'shadowsocks-tcp': 'open' },
      portsOpen: { 8388: true },
    })
    mocks.testNodeDirectSpeed.mockResolvedValue({
      status: 'ok',
      speedMbps: 12.345,
    })
    mocks.readFile.mockResolvedValue(JSON.stringify({
      outbounds: [{ tag: 'Tokyo-ss-v4', type: 'shadowsocks' }],
    }))
  })

  it('refreshes provider instances, persists cache, creates subscriptions, and syncs manual nodes', async () => {
    const harness = createHarness({
      profile: profileWithCloudSubscription(),
    })

    await harness.api.refreshInstances(false, true)

    expect(mocks.listCloudInstances).toHaveBeenCalledTimes(1)
    expect(harness.instances.value).toEqual([
      expect.objectContaining({
        instanceId: 'node-1',
        provider: 'vultr',
        statusText: 'connected',
      }),
    ])
    expect(mocks.saveToOfflineCache).toHaveBeenCalledWith('nodes', harness.instances.value)
    expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(
      expect.objectContaining({ instanceId: 'node-1' }),
    )
    expect(harness.applyAllNodesToProfile).toHaveBeenCalledTimes(1)
    expect(harness.syncManualNodesIntoInstances).toHaveBeenCalled()
    expect(harness.loadingInstances.value).toBe(false)
  })

  it('uses offline cached instances without calling the provider API', async () => {
    const cached = [readyNode({ instanceId: 'cached-node', label: 'Cached' })]
    mocks.isOnline.value = false
    mocks.loadFromOfflineCache.mockReturnValue(cached)
    const harness = createHarness()

    await harness.api.refreshInstances()

    expect(mocks.listCloudInstances).not.toHaveBeenCalled()
    expect(harness.instances.value).toBe(cached)
    expect(harness.instancesUpdatedAt.value).toBeTypeOf('number')
    expect(harness.syncManualNodesIntoInstances).toHaveBeenCalled()
  })

  it('destroys manual nodes locally without calling the cloud provider', async () => {
    const manual = readyNode({ instanceId: 'manual-1', provider: 'manual' })
    const harness = createHarness({
      instances: [manual],
      manualNodes: [manual],
    })

    await harness.api.destroyInstance('manual-1')

    expect(mocks.destroyCloudInstance).not.toHaveBeenCalled()
    expect(harness.manualNodes.value).toEqual([])
    expect(harness.instances.value).toEqual([])
    expect(harness.saveManualNodes).toHaveBeenCalledTimes(1)
    expect(harness.removeSubscriptionForNode).toHaveBeenCalledWith('manual-1')
    expect(harness.destroyingInstance.value).toBe('')
  })

  it('records connectivity probes and updates protocol health', async () => {
    const harness = createHarness({
      instances: [readyNode()],
    })

    await harness.api.testNodeConnectivity('node-1')

    expect(mocks.testConnectivity).toHaveBeenCalledWith(
      '203.0.113.10',
      expect.objectContaining({
        tcpPorts: [8388],
        udpPorts: [8388],
        targets: expect.arrayContaining([
          { name: 'shadowsocks-tcp', port: 8388, network: 'tcp' },
          { name: 'shadowsocks-udp', port: 8388, network: 'udp' },
        ]),
      }),
    )
    expect(harness.instances.value[0]).toMatchObject({
      connectivityStatus: 'reachable',
      connectivityTesting: false,
    })
    expect(harness.recordConnectivitySample).toHaveBeenCalledWith(
      'node-1',
      'reachable',
      expect.objectContaining({ status: 'reachable' }),
    )
    expect(mocks.notifications.connectivityRestored).toHaveBeenCalledWith('Tokyo')
  })

  it('reads subscription outbounds and records rounded speed samples', async () => {
    const harness = createHarness({
      instances: [readyNode()],
    })

    await harness.api.testNodeSpeedTest('node-1')

    expect(mocks.readFile).toHaveBeenCalledWith('data/subscribes/cloud-node-1.json')
    expect(mocks.testNodeDirectSpeed).toHaveBeenCalledWith(
      [{ tag: 'Tokyo-ss-v4', type: 'shadowsocks' }],
      15,
    )
    expect(harness.instances.value[0]).toMatchObject({
      speedMbps: 12.35,
      speedTesting: false,
    })
    expect(harness.recordSpeedSample).toHaveBeenCalledWith('node-1', {
      speedMbps: 12.35,
      status: 'ok',
      error: undefined,
    })
  })
})
